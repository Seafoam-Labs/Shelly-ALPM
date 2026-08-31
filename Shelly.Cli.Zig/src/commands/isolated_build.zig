//! Operation-scoped systemd-nspawn backend for `shelly build --isolated`.
//!
//! Reviewed host inputs are materialized in a root-owned staging tree. The
//! checkout, host home, host package database, and runtime sockets are never
//! bind mounted into the container.

const std = @import("std");

pub const build_uid = "1000";
pub const build_user = "shelly-build";
pub const guest_source = "/build/source";
pub const guest_artifacts = "/build/artifacts";
const guest_executable_relative = "usr/local/libexec/shelly/shelly";
pub const guest_executable = "/" ++ guest_executable_relative;

const operation_parent = "/var/lib/shelly/build-roots/v1/operations";

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

    /// Bootstraps a clean Arch root. pacstrap is restricted to provisioning;
    /// the package build itself is always Shelly's native builder in nspawn.
    pub fn bootstrap(self: *Root, extra_packages: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{
            "/usr/bin/pacstrap",
            "-C",
            "/etc/pacman.conf",
            "-c",
            self.root_path,
            "base",
            "base-devel",
            "git",
            "ca-certificates",
        });
        try argv.appendSlice(self.allocator, extra_packages);
        try runInherited(self.io, argv.items);

        const root_argument = try std.fmt.allocPrint(self.allocator, "--root={s}", .{self.root_path});
        defer self.allocator.free(root_argument);
        try runInherited(self.io, &.{
            "/usr/bin/systemd-sysusers",
            root_argument,
            "--inline",
            "g shelly-build 1000",
            "--inline",
            "u shelly-build 1000:1000 \"Shelly build user\" /home/shelly-build /usr/bin/bash",
        });

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
        try runInherited(self.io, &.{
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
        });
    }

    /// Materializes only byte-exact inputs accepted by the host review. This
    /// avoids carrying unrelated checkout state or build caches into the
    /// guest, and makes the guest digest check independent of copy timing.
    pub fn stageReviewedInputs(
        self: *Root,
        pkgbuild_contents: []const u8,
        reviewed_files: anytype,
    ) !void {
        try self.writeReviewedInput("PKGBUILD", pkgbuild_contents, 0o644);
        for (reviewed_files) |file|
            try self.writeReviewedInput(file.name, file.contents, file.permissions);
        try runInherited(self.io, &.{
            "/usr/bin/chown",
            "-R",
            "--",
            "1000:1000",
            self.source_path,
        });
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
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = contents,
            .flags = .{ .permissions = .fromMode(permissions & 0o777) },
        });
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

    pub fn writeBuildConfiguration(self: *Root, contents: []const u8) !void {
        const path = try self.rootJoin("etc/shellybuild.conf");
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = contents,
            .flags = .{ .permissions = .fromMode(0o644) },
        });
    }

    pub fn run(self: *Root, child_arguments: []const []const u8) !void {
        const argv = try nspawnArguments(self.allocator, self.root_path, child_arguments);
        defer self.allocator.free(argv);
        try runInherited(self.io, argv);
    }

    pub fn exportArtifacts(
        self: *Root,
        destination: []const u8,
        overwrite: bool,
        owner_uid: std.Io.File.Uid,
        owner_gid: std.Io.File.Gid,
    ) !usize {
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.artifact_path, .{ .iterate = true });
        defer directory.close(self.io);
        // The destination must already exist. Opening it once gives every
        // subsequent create/rename a stable directory handle even if an
        // untrusted user concurrently changes the path name.
        var destination_directory = try std.Io.Dir.cwd().openDir(self.io, destination, .{ .iterate = true });
        defer destination_directory.close(self.io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or !isPackageArtifact(entry.name)) continue;
            var random: [16]u8 = undefined;
            self.io.random(&random);
            const suffix = std.fmt.bytesToHex(random, .lower);
            var temporary_name_buffer: [64]u8 = undefined;
            const temporary_name = try std.fmt.bufPrint(
                &temporary_name_buffer,
                ".shelly-export-{s}",
                .{suffix},
            );

            var source = try directory.openFile(self.io, entry.name, .{});
            defer source.close(self.io);
            var temporary = try destination_directory.createFile(self.io, temporary_name, .{
                .exclusive = true,
                .permissions = .fromMode(0o644),
            });
            var temporary_exists = true;
            defer {
                temporary.close(self.io);
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

            if (overwrite) {
                try destination_directory.rename(
                    temporary_name,
                    destination_directory,
                    entry.name,
                    self.io,
                );
            } else {
                destination_directory.renamePreserve(
                    temporary_name,
                    destination_directory,
                    entry.name,
                    self.io,
                ) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.ArtifactAlreadyExists,
                    else => return err,
                };
            }
            temporary_exists = false;
            count += 1;
        }
        if (count == 0) return error.NoBuildArtifacts;
        return count;
    }

    fn rootJoin(self: *Root, relative: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root_path, relative });
    }
};

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

fn runInherited(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(io);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.IsolatedCommandFailed,
        else => return error.IsolatedCommandFailed,
    }
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

    try root.writeReviewedInput("patches/fix.patch", "reviewed\n", 0o750);
    const contents = try temporary.dir.readFileAlloc(io, "patches/fix.patch", allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("reviewed\n", contents);
    const stat = try temporary.dir.statFile(io, "patches/fix.patch", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o750), stat.permissions.toMode() & 0o777);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(io, "unreviewed.cache", .{ .follow_symlinks = false }),
    );
}

test "artifact export accepts package archives but not detached signatures" {
    try std.testing.expect(isPackageArtifact("demo-1-1-any.pkg.tar.zst"));
    try std.testing.expect(!isPackageArtifact("demo-1-1-any.pkg.tar.zst.sig"));
    try std.testing.expect(!isPackageArtifact("build.log"));
}
