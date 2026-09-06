//! Operation-scoped systemd-nspawn backend for `shelly build --isolated`.
//!
//! Reviewed host inputs are materialized in a root-owned staging tree. The
//! checkout, host home, host package database, and runtime sockets are never
//! bind mounted into the container.

const std = @import("std");
const Zigalpm = @import("Zigalpm");

pub const build_uid = "1000";
pub const build_user = "shelly-build";
pub const guest_source = "/build/source";
pub const guest_artifacts = "/build/artifacts";

/// Package identity retained from libalpm validation. Filenames are kept
/// separately from package names because archive naming is not an API.
pub const ValidatedArtifact = struct {
    package_name: []u8,
    filename: []u8,

    pub fn deinit(self: ValidatedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.filename);
    }
};

pub fn deinitValidatedArtifacts(allocator: std.mem.Allocator, artifacts: []ValidatedArtifact) void {
    for (artifacts) |artifact| artifact.deinit(allocator);
    allocator.free(artifacts);
}

pub const ExportedArtifact = struct {
    package_name: []u8,
    path: []u8,

    pub fn deinit(self: ExportedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.path);
    }
};

pub fn deinitExportedArtifacts(allocator: std.mem.Allocator, artifacts: []ExportedArtifact) void {
    for (artifacts) |artifact| artifact.deinit(allocator);
    allocator.free(artifacts);
}
const guest_executable_relative = "usr/local/libexec/shelly/shelly";
pub const guest_executable = "/" ++ guest_executable_relative;
const source_keys_relative = "usr/local/libexec/shelly/source-keys.asc";
pub const guest_source_keys = "/" ++ source_keys_relative;

const operation_parent = "/var/lib/shelly/build-roots/v1/operations";

const BootstrapOutputContext = struct {
    operation: *const Zigalpm.Operation,

    fn handle(data: ?*anyopaque, stream: Zigalpm.process_runner.StreamKind, line: []const u8) void {
        const self: *BootstrapOutputContext = @ptrCast(@alignCast(data.?));
        self.operation.status(
            if (stream == .stderr) .warning else .information,
            line,
            "build.isolation.bootstrap",
            null,
        );
    }
};

pub const Root = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation_path: []u8,
    root_path: []u8,
    source_path: []u8,
    artifact_path: []u8,
    retain_on_failure: bool = false,
    succeeded: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !Root {
        try std.Io.Dir.cwd().createDirPath(io, operation_parent);
        try std.Io.Dir.cwd().setFilePermissions(
            io,
            operation_parent,
            .fromMode(0o700),
            .{},
        );

        var random: [16]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const operation_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ operation_parent, suffix },
        );
        errdefer allocator.free(operation_path);
        try validateOperationPath(operation_path);
        try std.Io.Dir.cwd().createDirPath(io, operation_path);
        errdefer std.Io.Dir.cwd().deleteTree(io, operation_path) catch {};
        try std.Io.Dir.cwd().setFilePermissions(io, operation_path, .fromMode(0o700), .{});

        const root_path = try std.fs.path.join(allocator, &.{ operation_path, "root" });
        errdefer allocator.free(root_path);
        const source_path = try std.fs.path.join(allocator, &.{ root_path, "build/source" });
        errdefer allocator.free(source_path);
        const artifact_path = try std.fs.path.join(allocator, &.{ root_path, "build/artifacts" });
        errdefer allocator.free(artifact_path);
        try std.Io.Dir.cwd().createDirPath(io, source_path);
        try std.Io.Dir.cwd().createDirPath(io, artifact_path);
        const marker_path = try std.fs.path.join(allocator, &.{ root_path, Zigalpm.alpm.bootstrap.marker_name });
        defer allocator.free(marker_path);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = marker_path,
            .data = "managed by shelly isolated build\n",
            .flags = .{ .permissions = .fromMode(0o600) },
        });

        return .{
            .allocator = allocator,
            .io = io,
            .operation_path = operation_path,
            .root_path = root_path,
            .source_path = source_path,
            .artifact_path = artifact_path,
        };
    }

    pub fn deinit(self: *Root) void {
        if (self.succeeded or !self.retain_on_failure)
            std.Io.Dir.cwd().deleteTree(self.io, self.operation_path) catch {};
        self.allocator.free(self.artifact_path);
        self.allocator.free(self.source_path);
        self.allocator.free(self.root_path);
        self.allocator.free(self.operation_path);
        self.* = undefined;
    }

    /// Bootstraps a clean Arch root through Shelly's own libalpm backend. The
    /// helper process is isolated in a private mount/PID namespace so package
    /// scriptlets receive the standard virtual filesystems without introducing
    /// mounts into the coordinator's namespace.
    pub fn bootstrap(
        self: *Root,
        environ: std.process.Environ,
        executable: []const u8,
        extra_packages: []const []const u8,
        operation: *const Zigalpm.Operation,
    ) !void {
        const argv = try shellystrapArguments(
            self.allocator,
            executable,
            self.root_path,
            extra_packages,
        );
        defer self.allocator.free(argv);
        var output_context: BootstrapOutputContext = .{ .operation = operation };
        const exit_code = try Zigalpm.process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            environ,
            argv,
            null,
            null,
            .{ .function = BootstrapOutputContext.handle, .data = &output_context },
            operation,
        );
        if (exit_code != 0) return error.IsolatedBootstrapFailed;

        const marker_path = try self.rootJoin(Zigalpm.alpm.bootstrap.marker_name);
        defer self.allocator.free(marker_path);
        std.Io.Dir.cwd().deleteFile(self.io, marker_path) catch {};

        const root_argument = try std.fmt.allocPrint(self.allocator, "--root={s}", .{self.root_path});
        defer self.allocator.free(root_argument);
        try self.runCancellable(environ, &.{
            "/usr/bin/systemd-sysusers",
            root_argument,
            "--inline",
            "g shelly-build 1000",
            "--inline",
            "u shelly-build 1000:1000 \"Shelly build user\" /home/shelly-build /usr/bin/bash",
        }, operation);

        const home_path = try self.rootJoin("home/shelly-build");
        defer self.allocator.free(home_path);
        const executable_directory = try self.rootJoin("usr/local/libexec/shelly");
        defer self.allocator.free(executable_directory);
        const work_path = try self.rootJoin("build/work");
        defer self.allocator.free(work_path);
        const sources_path = try self.rootJoin("build/sources");
        defer self.allocator.free(sources_path);
        const logs_path = try self.rootJoin("build/logs");
        defer self.allocator.free(logs_path);
        try std.Io.Dir.cwd().createDirPath(self.io, home_path);
        try std.Io.Dir.cwd().createDirPath(self.io, executable_directory);
        try std.Io.Dir.cwd().createDirPath(self.io, work_path);
        try std.Io.Dir.cwd().createDirPath(self.io, sources_path);
        try std.Io.Dir.cwd().createDirPath(self.io, logs_path);
        try self.runCancellable(environ, &.{
            "/usr/bin/chown",
            "-R",
            "--",
            "1000:1000",
            self.source_path,
            self.artifact_path,
            work_path,
            sources_path,
            logs_path,
            home_path,
        }, operation);
    }

    /// Materializes only byte-exact inputs accepted by the host review. This
    /// avoids carrying unrelated checkout state or build caches into the
    /// guest, and makes the guest digest check independent of copy timing.
    pub fn stageReviewedInputs(
        self: *Root,
        environ: std.process.Environ,
        pkgbuild_contents: []const u8,
        reviewed_files: anytype,
        operation: *const Zigalpm.Operation,
    ) !void {
        try self.writeReviewedInput("PKGBUILD", pkgbuild_contents, 0o644);
        for (reviewed_files) |file|
            try self.writeReviewedInput(file.name, file.contents, file.permissions);
        try self.runCancellable(environ, &.{
            "/usr/bin/chown",
            "-R",
            "--",
            "1000:1000",
            self.source_path,
        }, operation);
    }

    fn writeReviewedInput(
        self: *Root,
        name: []const u8,
        contents: []const u8,
        permissions: u32,
    ) !void {
        try validateReviewedInputPath(name);
        const path = try std.fs.path.join(self.allocator, &.{ self.source_path, name });
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent|
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{
            .permissions = .fromMode(0o600),
        });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, contents);
        // Permissions are part of the review digest and must survive umask.
        try file.setPermissions(self.io, .fromMode(permissions & 0o777));
    }

    pub fn stageExecutable(self: *Root, executable: []const u8) !void {
        // nspawn mounts a fresh tmpfs on /run, so coordinator payloads staged
        // there would be hidden before execve(). /usr/local remains part of
        // the operation-scoped root and is not exported from the guest.
        const destination = try self.rootJoin(guest_executable_relative);
        defer self.allocator.free(destination);
        try std.Io.Dir.copyFile(.cwd(), executable, .cwd(), destination, self.io, .{});
        try std.Io.Dir.cwd().setFilePermissions(self.io, destination, .fromMode(0o755), .{});
    }

    pub fn stageSourcePgpKeys(self: *Root, contents: []const u8) !void {
        const path = try self.rootJoin(source_keys_relative);
        defer self.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, contents);
        // Public keys are read by the unprivileged guest, outside the reviewed source tree.
        try file.setPermissions(self.io, .fromMode(0o644));
    }

    pub fn writeBuildConfiguration(self: *Root, contents: []const u8) !void {
        const path = try self.rootJoin("etc/shellybuild.conf");
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = contents,
            .flags = .{ .permissions = .fromMode(0o644) },
        });
    }

    pub fn run(
        self: *Root,
        environ: std.process.Environ,
        child_arguments: []const []const u8,
        operation: *const Zigalpm.Operation,
    ) !void {
        const argv = try nspawnArguments(self.allocator, self.root_path, child_arguments);
        defer self.allocator.free(argv);
        try self.runCancellable(environ, argv, operation);
    }

    pub fn exportArtifacts(
        self: *Root,
        destination: []const u8,
        validated_artifacts: []const ValidatedArtifact,
        overwrite: bool,
        owner_uid: std.Io.File.Uid,
        owner_gid: std.Io.File.Gid,
    ) ![]ExportedArtifact {
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.artifact_path, .{ .iterate = true });
        defer directory.close(self.io);
        // The destination must already exist. Opening it once gives every
        // subsequent create/rename a stable directory handle even if an
        // untrusted user concurrently changes the path name.
        var destination_directory = try std.Io.Dir.cwd().openDir(self.io, destination, .{ .iterate = true });
        defer destination_directory.close(self.io);
        var exported: std.ArrayList(ExportedArtifact) = .empty;
        errdefer {
            for (exported.items) |artifact| artifact.deinit(self.allocator);
            exported.deinit(self.allocator);
        }
        for (validated_artifacts) |validated| {
            var random: [16]u8 = undefined;
            self.io.random(&random);
            const suffix = std.fmt.bytesToHex(random, .lower);
            var temporary_name_buffer: [64]u8 = undefined;
            const temporary_name = try std.fmt.bufPrint(
                &temporary_name_buffer,
                ".shelly-export-{s}",
                .{suffix},
            );

            var source = try directory.openFile(self.io, validated.filename, .{});
            var source_open = true;
            defer if (source_open) source.close(self.io);
            var temporary = try destination_directory.createFile(self.io, temporary_name, .{
                .exclusive = true,
                .permissions = .fromMode(0o644),
            });
            var temporary_open = true;
            var temporary_exists = true;
            defer {
                if (temporary_open) temporary.close(self.io);
                if (temporary_exists)
                    destination_directory.deleteFile(self.io, temporary_name) catch {};
            }
            var read_buffer: [64 * 1024]u8 = undefined;
            var reader = source.readerStreaming(self.io, &read_buffer);
            var write_buffer: [64 * 1024]u8 = undefined;
            var writer = temporary.writerStreaming(self.io, &write_buffer);
            _ = try reader.interface.streamRemaining(&writer.interface);
            try writer.interface.flush();
            try temporary.setOwner(self.io, owner_uid, owner_gid);
            // Both descriptors are closed before publication, so a returned
            // artifact is guaranteed to be completely flushed and no guest
            // archive remains open across the atomic rename.
            temporary.close(self.io);
            temporary_open = false;
            source.close(self.io);
            source_open = false;

            if (overwrite) {
                try destination_directory.rename(
                    temporary_name,
                    destination_directory,
                    validated.filename,
                    self.io,
                );
            } else {
                destination_directory.renamePreserve(
                    temporary_name,
                    destination_directory,
                    validated.filename,
                    self.io,
                ) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.ArtifactAlreadyExists,
                    else => return err,
                };
            }
            temporary_exists = false;
            const package_name = try self.allocator.dupe(u8, validated.package_name);
            errdefer self.allocator.free(package_name);
            const path = try std.fs.path.join(self.allocator, &.{ destination, validated.filename });
            try exported.append(self.allocator, .{
                .package_name = package_name,
                .path = path,
            });
        }
        if (exported.items.len == 0) return error.NoBuildArtifacts;
        return exported.toOwnedSlice(self.allocator);
    }

    fn rootJoin(self: *Root, relative: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root_path, relative });
    }

    fn runCancellable(
        self: *Root,
        environ: std.process.Environ,
        argv: []const []const u8,
        operation: *const Zigalpm.Operation,
    ) !void {
        var output_context: BootstrapOutputContext = .{ .operation = operation };
        const exit_code = try Zigalpm.process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            environ,
            argv,
            null,
            null,
            .{ .function = BootstrapOutputContext.handle, .data = &output_context },
            operation,
        );
        if (exit_code != 0) return error.IsolatedCommandFailed;
    }
};

/// Constructs the re-exec boundary used instead of pacstrap. All returned
/// strings are borrowed; only the slice itself is owned by the caller.
pub fn shellystrapArguments(
    allocator: std.mem.Allocator,
    executable: []const u8,
    root_path: []const u8,
    extra_packages: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "/usr/bin/unshare",
        "--fork",
        "--pid",
        "--mount",
        "--propagation",
        "private",
        "--kill-child=KILL",
        "--forward-signals",
        executable,
        Zigalpm.alpm.bootstrap.wrapper_argument,
        "--root",
        root_path,
        "--config",
        "/etc/pacman.conf",
        "--gpgdir",
        "/etc/pacman.d/gnupg",
        "--",
        "base",
        "base-devel",
        "git",
        "ca-certificates",
    });
    try argv.appendSlice(allocator, extra_packages);
    return argv.toOwnedSlice(allocator);
}

pub fn nspawnArguments(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    child_arguments: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "/usr/bin/systemd-nspawn",
        "--settings=no",
        "--register=no",
        "--quiet",
        "--console=pipe",
        "--link-journal=no",
        "--private-users=pick",
        "--private-users-ownership=map",
        "--no-new-privileges=yes",
        "--directory",
        root_path,
        "--uid",
        build_user,
        "--chdir",
        guest_source,
        "--setenv=HOME=/home/shelly-build",
        "--setenv=XDG_CONFIG_HOME=/home/shelly-build/.config",
        "--setenv=XDG_CACHE_HOME=/home/shelly-build/.cache",
        "--setenv=PATH=/usr/local/sbin:/usr/local/bin:/usr/bin",
        guest_executable,
    });
    try argv.appendSlice(allocator, child_arguments);
    return argv.toOwnedSlice(allocator);
}

pub fn validateOperationPath(path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, operation_parent ++ "/"))
        return error.InvalidIsolationPath;
    const suffix = path[operation_parent.len + 1 ..];
    if (suffix.len != 32) return error.InvalidIsolationPath;
    for (suffix) |byte| if (!std.ascii.isHex(byte)) return error.InvalidIsolationPath;
}

pub fn validateReviewedInputPath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path))
        return error.UnsafePkgbuildSourcePath;
    var components = std.fs.path.componentIterator(path);
    var depth: usize = 0;
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".")) continue;
        if (std.mem.eql(u8, component.name, "..")) {
            if (depth == 0) return error.UnsafePkgbuildSourcePath;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
}

pub fn isPackageArtifact(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, ".sig")) return false;
    const marker = std.mem.indexOf(u8, name, ".pkg.tar.") orelse return false;
    if (marker == 0) return false;
    return true;
}

test "shellystrap invocation uses a private cancellable namespace and native helper" {
    const root_path = "/var/lib/shelly/build-roots/v1/operations/0123456789abcdef0123456789abcdef/root";
    const argv = try shellystrapArguments(
        std.testing.allocator,
        "/usr/bin/shelly",
        root_path,
        &.{ "cmake", "ninja" },
    );
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqualStrings("/usr/bin/unshare", argv[0]);
    try std.testing.expect(containsArgument(argv, "--mount"));
    try std.testing.expect(containsArgument(argv, "--pid"));
    try std.testing.expect(containsArgument(argv, "private"));
    try std.testing.expect(containsArgument(argv, "--kill-child=KILL"));
    try std.testing.expect(containsArgument(argv, "--forward-signals"));
    try std.testing.expect(containsArgument(argv, Zigalpm.alpm.bootstrap.wrapper_argument));
    try std.testing.expect(containsArgument(argv, root_path));
    try std.testing.expect(containsArgument(argv, "base-devel"));
    try std.testing.expect(containsArgument(argv, "cmake"));
    try std.testing.expect(containsArgument(argv, "ninja"));
    try std.testing.expect(!containsArgument(argv, "/usr/bin/pacstrap"));
}

test "nspawn invocation is unprivileged namespaced and contains no host binds" {
    const argv = try nspawnArguments(
        std.testing.allocator,
        "/var/lib/shelly/build-roots/v1/operations/0123456789abcdef0123456789abcdef/root",
        &.{ "build", "--coordinator-child", "/build/source/PKGBUILD" },
    );
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualStrings("/usr/bin/systemd-nspawn", argv[0]);
    try std.testing.expect(containsArgument(argv, "--private-users=pick"));
    try std.testing.expect(containsArgument(argv, "--private-users-ownership=map"));
    try std.testing.expect(containsArgument(argv, "shelly-build"));
    try std.testing.expect(containsArgument(argv, guest_executable));
    try std.testing.expect(!std.mem.startsWith(u8, guest_executable, "/run/"));
    for (argv) |argument| {
        try std.testing.expect(!std.mem.startsWith(u8, argument, "--bind"));
        try std.testing.expect(!std.mem.eql(u8, argument, "makepkg"));
    }
}

fn containsArgument(arguments: []const []const u8, wanted: []const u8) bool {
    for (arguments) |argument|
        if (std.mem.eql(u8, argument, wanted)) return true;
    return false;
}

test "operation paths are restricted to random children of the managed parent" {
    try validateOperationPath("/var/lib/shelly/build-roots/v1/operations/0123456789abcdef0123456789abcdef");
    try std.testing.expectError(error.InvalidIsolationPath, validateOperationPath("/"));
    try std.testing.expectError(error.InvalidIsolationPath, validateOperationPath("/var/lib/shelly/build-roots/v1/operations/../host"));
}

test "reviewed input paths cannot escape the staged source root" {
    try validateReviewedInputPath("patches/fix.patch");
    try validateReviewedInputPath("patches/../fix.patch");
    try std.testing.expectError(error.UnsafePkgbuildSourcePath, validateReviewedInputPath("../host"));
    try std.testing.expectError(error.UnsafePkgbuildSourcePath, validateReviewedInputPath("patches/../../host"));
    try std.testing.expectError(error.UnsafePkgbuildSourcePath, validateReviewedInputPath("/etc/passwd"));
}

test "reviewed inputs are materialized with exact bytes and permissions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_path);
    const unused = try allocator.dupe(u8, "unused");
    defer allocator.free(unused);
    var root: Root = .{
        .allocator = allocator,
        .io = io,
        .operation_path = unused,
        .root_path = unused,
        .source_path = source_path,
        .artifact_path = unused,
    };

    for ([_]u32{ 0o600, 0o640, 0o644, 0o660, 0o664, 0o750, 0o770 }) |mode| {
        const name = try std.fmt.allocPrint(allocator, "patches/mode-{o}.patch", .{mode});
        defer allocator.free(name);
        try root.writeReviewedInput(name, "reviewed\x00\xff\n", mode);
        try expectStagedInput(temporary.dir, name, "reviewed\x00\xff\n", mode);
    }
    try temporary.dir.writeFile(io, .{ .sub_path = "overwrite.patch", .data = "old longer contents\n" });
    try temporary.dir.setFilePermissions(io, "overwrite.patch", .fromMode(0o770), .{});
    try root.writeReviewedInput("overwrite.patch", "short\n", 0o640);
    try expectStagedInput(temporary.dir, "overwrite.patch", "short\n", 0o640);
    try root.writeReviewedInput("overwrite.patch", "group writable\n", 0o660);
    try expectStagedInput(temporary.dir, "overwrite.patch", "group writable\n", 0o660);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(io, "unreviewed.cache", .{ .follow_symlinks = false }),
    );
}

fn expectStagedInput(directory: std.Io.Dir, name: []const u8, expected: []const u8, mode: u32) !void {
    const contents = try directory.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
    const stat = try directory.statFile(std.testing.io, name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(mode, stat.permissions.toMode() & 0o777);
}

test "staged reviewed inputs preserve the host digest and reject real changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var host = std.testing.tmpDir(.{});
    defer host.cleanup();
    var guest = std.testing.tmpDir(.{});
    defer guest.cleanup();
    const host_path = try host.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(host_path);
    const guest_path = try guest.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(guest_path);
    const guest_pkgbuild = try std.fs.path.join(allocator, &.{ guest_path, "PKGBUILD" });
    defer allocator.free(guest_pkgbuild);
    const content =
        \\pkgname=staged-review
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('related.txt')
        \\sha256sums=('SKIP')
        \\package() { :; }
    ;
    try host.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = content });
    try host.dir.writeFile(io, .{ .sub_path = "related.txt", .data = "reviewed\n" });
    try host.dir.setFilePermissions(io, "related.txt", .fromMode(0o660), .{});
    var host_build = try (Zigalpm.pkgbuild.Parser{ .allocator = allocator, .io = io }).parser_content(content, host_path);
    defer host_build.deinit(allocator);
    var review = try Zigalpm.builder.preparePkgbuildReview(allocator, io, host_path, content, &.{host_build});
    defer review.deinit();
    try std.testing.expectEqual(@as(usize, 1), review.reviewed_files.len);
    try std.testing.expectEqual(@as(u32, 0o660), review.reviewed_files[0].permissions);

    var unused: [0]u8 = .{};
    var root: Root = .{
        .allocator = allocator,
        .io = io,
        .operation_path = &unused,
        .root_path = &unused,
        .source_path = guest_path,
        .artifact_path = &unused,
    };
    try root.writeReviewedInput("PKGBUILD", content, 0o644);
    for (review.reviewed_files) |file|
        try root.writeReviewedInput(file.name, file.contents, file.permissions);

    const staged_content = try guest.dir.readFileAlloc(io, "PKGBUILD", allocator, .limited(1024));
    defer allocator.free(staged_content);
    var guest_build = try (Zigalpm.pkgbuild.Parser{ .allocator = allocator, .io = io }).parser_content(staged_content, guest_path);
    defer guest_build.deinit(allocator);
    var guest_review = try Zigalpm.builder.preparePkgbuildReview(allocator, io, guest_path, staged_content, &.{guest_build});
    defer guest_review.deinit();
    try std.testing.expectEqualSlices(u8, &review.digest, &guest_review.digest);
    try review.verifyCurrent(allocator, io, guest_pkgbuild, guest_path);

    try guest.dir.writeFile(io, .{ .sub_path = "related.txt", .data = "changed\n" });
    try std.testing.expectError(error.ReviewedPkgbuildChanged, review.verifyCurrent(allocator, io, guest_pkgbuild, guest_path));
    try guest.dir.writeFile(io, .{ .sub_path = "related.txt", .data = "reviewed\n" });
    try review.verifyCurrent(allocator, io, guest_pkgbuild, guest_path);
    try guest.dir.setFilePermissions(io, "related.txt", .fromMode(0o640), .{});
    try std.testing.expectError(error.ReviewedPkgbuildChanged, review.verifyCurrent(allocator, io, guest_pkgbuild, guest_path));
    try guest.dir.setFilePermissions(io, "related.txt", .fromMode(0o660), .{});
    try review.verifyCurrent(allocator, io, guest_pkgbuild, guest_path);
    try guest.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = content ++ "\n# changed\n" });
    try std.testing.expectError(error.ReviewedPkgbuildChanged, review.verifyCurrent(allocator, io, guest_pkgbuild, guest_path));
}

test "isolated public source key bundle is readable under restrictive umasks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var unused: [0]u8 = .{};
    var root: Root = .{
        .allocator = allocator,
        .io = io,
        .operation_path = &unused,
        .root_path = path,
        .source_path = &unused,
        .artifact_path = &unused,
    };
    try temporary.dir.createDirPath(io, "usr/local/libexec/shelly");
    const keys = @embedFile("fixtures/source-pgp/public.asc");
    try root.stageSourcePgpKeys(keys);
    try expectStagedInput(temporary.dir, source_keys_relative, keys, 0o644);
}

test "artifact export accepts package archives but not detached signatures" {
    try std.testing.expect(isPackageArtifact("demo-1-1-any.pkg.tar.zst"));
    try std.testing.expect(!isPackageArtifact("demo-1-1-any.pkg.tar.zst.sig"));
    try std.testing.expect(!isPackageArtifact("build.log"));
}

test "artifact export returns validated package names and exact final absolute paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "guest");
    try temporary.dir.createDirPath(io, "destination");
    try temporary.dir.writeFile(io, .{
        .sub_path = "guest/demo-1-1-any.pkg.tar.zst",
        .data = "archive bytes",
    });
    const root_path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    const artifact_path = try temporary.dir.realPathFileAlloc(io, "guest", allocator);
    defer allocator.free(artifact_path);
    const destination = try temporary.dir.realPathFileAlloc(io, "destination", allocator);
    defer allocator.free(destination);
    var root: Root = .{
        .allocator = allocator,
        .io = io,
        .operation_path = root_path,
        .root_path = root_path,
        .source_path = root_path,
        .artifact_path = artifact_path,
    };
    const validated = [_]ValidatedArtifact{.{
        .package_name = @constCast("demo"),
        .filename = @constCast("demo-1-1-any.pkg.tar.zst"),
    }};
    const exported = try root.exportArtifacts(
        destination,
        &validated,
        false,
        @intCast(std.os.linux.geteuid()),
        @intCast(std.os.linux.getegid()),
    );
    defer deinitExportedArtifacts(allocator, exported);
    try std.testing.expectEqual(@as(usize, 1), exported.len);
    try std.testing.expectEqualStrings("demo", exported[0].package_name);
    const expected = try std.fs.path.join(allocator, &.{ destination, "demo-1-1-any.pkg.tar.zst" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, exported[0].path);
    const contents = try temporary.dir.readFileAlloc(
        io,
        "destination/demo-1-1-any.pkg.tar.zst",
        allocator,
        .limited(1024),
    );
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("archive bytes", contents);
}

test "failed or cancelled isolated roots remove their complete operation directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "operation/root/build/artifacts");
    const operation_path = try temporary.dir.realPathFileAlloc(io, "operation", allocator);
    const root_path = try temporary.dir.realPathFileAlloc(io, "operation/root", allocator);
    const source_path = try std.fs.path.join(allocator, &.{ root_path, "build/source" });
    const artifact_path = try temporary.dir.realPathFileAlloc(io, "operation/root/build/artifacts", allocator);
    var root: Root = .{
        .allocator = allocator,
        .io = io,
        .operation_path = operation_path,
        .root_path = root_path,
        .source_path = source_path,
        .artifact_path = artifact_path,
        .succeeded = false,
    };
    root.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(io, "operation", .{}),
    );
}
