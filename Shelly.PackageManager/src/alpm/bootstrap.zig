//! Native Arch root provisioning used by Shelly's isolated build coordinator.
//!
//! The public coordinator re-executes Shelly in a private mount/PID namespace.
//! This module then gives libalpm explicit target-owned paths and performs the
//! repository transaction without depending on the `pacstrap` shell script.

const std = @import("std");
const manager_module = @import("manager.zig");
const events = @import("events.zig");
const process_runner = @import("../aur/builder.zig");

pub const wrapper_argument = "__shellystrap";
pub const marker_name = ".shelly-bootstrap-root";

pub const Options = struct {
    root_path: []const u8,
    config_path: []const u8 = "/etc/pacman.conf",
    host_gpg_directory: []const u8 = "/etc/pacman.d/gnupg",
    packages: []const []const u8,
};

pub const Result = struct {
    installed_package_count: usize,
};

/// Entry point for the reserved, re-executed helper mode. It intentionally
/// writes diagnostics only to stderr and has no access to the normal CLI/UI.
pub fn runInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    arguments: []const []const u8,
) u8 {
    const options = parseArguments(arguments) catch |err| {
        stderr.print("shellystrap: invalid request: {t}\n", .{err}) catch {};
        return 2;
    };
    _ = bootstrapReporting(allocator, io, environ, options, stderr) catch |err| {
        stderr.print("shellystrap: provisioning failed: {t}\n", .{err}) catch {};
        return 1;
    };
    return 0;
}

pub fn parseArguments(arguments: []const []const u8) !Options {
    var root_path: ?[]const u8 = null;
    var config_path: []const u8 = "/etc/pacman.conf";
    var gpg_directory: []const u8 = "/etc/pacman.d/gnupg";
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--")) {
            const packages = arguments[index + 1 ..];
            if (root_path == null or packages.len == 0) return error.InvalidBootstrapArguments;
            return .{
                .root_path = root_path.?,
                .config_path = config_path,
                .host_gpg_directory = gpg_directory,
                .packages = packages,
            };
        }
        if (std.mem.eql(u8, argument, "--root")) {
            index += 1;
            if (index >= arguments.len or root_path != null) return error.InvalidBootstrapArguments;
            root_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--config")) {
            index += 1;
            if (index >= arguments.len) return error.InvalidBootstrapArguments;
            config_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--gpgdir")) {
            index += 1;
            if (index >= arguments.len) return error.InvalidBootstrapArguments;
            gpg_directory = arguments[index];
        } else {
            return error.InvalidBootstrapArguments;
        }
    }
    return error.InvalidBootstrapArguments;
}

pub fn bootstrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) !Result {
    return bootstrapReporting(allocator, io, environ, options, null);
}

const DiagnosticOutput = struct {
    stderr: *std.Io.Writer,

    fn handleError(data: ?*anyopaque, args: events.ErrorArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.stderr.print("shellystrap: libalpm: {s}\n", .{
            std.mem.trimEnd(u8, args.message, "\r\n"),
        }) catch {};
    }

    fn handleScriptlet(data: ?*anyopaque, args: events.ScriptletArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.stderr.print("shellystrap: scriptlet: {s}\n", .{
            std.mem.trimEnd(u8, args.line, "\r\n"),
        }) catch {};
    }
};

const RootFinalizer = struct {
    name: []const u8,
    arguments: []const []const u8,
};

const root_finalizers = [_]RootFinalizer{
    .{ .name = "ldconfig", .arguments = &.{"/usr/bin/ldconfig"} },
    .{ .name = "systemd-sysusers", .arguments = &.{"/usr/bin/systemd-sysusers"} },
    .{ .name = "systemd-tmpfiles", .arguments = &.{ "/usr/bin/systemd-tmpfiles", "--create" } },
    .{ .name = "update-ca-trust", .arguments = &.{"/usr/bin/update-ca-trust"} },
};

const FinalizerOutput = struct {
    writer: ?*std.Io.Writer,
    name: []const u8,

    fn handle(data: ?*anyopaque, _: process_runner.StreamKind, line: []const u8) void {
        const self: *FinalizerOutput = @ptrCast(@alignCast(data.?));
        const writer = self.writer orelse return;
        writer.print("shellystrap: {s}: {s}\n", .{ self.name, line }) catch {};
    }
};

fn rootFinalizerArguments(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    finalizer: RootFinalizer,
) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, finalizer.arguments.len + 2);
    argv[0] = "/usr/bin/chroot";
    argv[1] = root_path;
    @memcpy(argv[2..], finalizer.arguments);
    return argv;
}

fn reportFinalizerFailure(
    writer: ?*std.Io.Writer,
    name: []const u8,
    detail: []const u8,
) void {
    const destination = writer orelse return;
    destination.print("shellystrap: {s}: {s}\n", .{ name, detail }) catch {};
}

fn finalizeRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    root_path: []const u8,
    diagnostic_writer: ?*std.Io.Writer,
) !void {
    for (root_finalizers) |finalizer| {
        const executable = std.mem.trimStart(u8, finalizer.arguments[0], "/");
        try requireFile(io, allocator, root_path, executable);
        const argv = try rootFinalizerArguments(allocator, root_path, finalizer);
        defer allocator.free(argv);
        var output: FinalizerOutput = .{
            .writer = diagnostic_writer,
            .name = finalizer.name,
        };
        const exit_code = process_runner.runStreamingWithEnvironmentOperation(
            allocator,
            io,
            environ,
            argv,
            null,
            null,
            .{ .function = FinalizerOutput.handle, .data = &output },
            null,
        ) catch |err| {
            var detail_buffer: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "unable to start: {t}", .{err}) catch
                "unable to start";
            reportFinalizerFailure(diagnostic_writer, finalizer.name, detail);
            return error.BootstrapFinalizerFailed;
        };
        if (exit_code != 0) {
            var detail_buffer: [64]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "exited with status {d}", .{exit_code}) catch
                "exited unsuccessfully";
            reportFinalizerFailure(diagnostic_writer, finalizer.name, detail);
            return error.BootstrapFinalizerFailed;
        }
    }
}

fn bootstrapReporting(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
    diagnostic_writer: ?*std.Io.Writer,
) !Result {
    if (std.os.linux.geteuid() != 0) return error.RootPrivilegesRequired;
    try validateRoot(allocator, io, options.root_path);
    if (!std.fs.path.isAbsolute(options.config_path) or
        !std.fs.path.isAbsolute(options.host_gpg_directory))
        return error.InvalidBootstrapPath;

    const database_path = try rootJoin(allocator, options.root_path, "var/lib/pacman");
    defer allocator.free(database_path);
    const cache_path = try rootJoin(allocator, options.root_path, "var/cache/pacman/pkg");
    defer allocator.free(cache_path);
    const log_path = try rootJoin(allocator, options.root_path, "var/log/pacman.log");
    defer allocator.free(log_path);
    const target_gpg_path = try rootJoin(allocator, options.root_path, "etc/pacman.d/gnupg");
    defer allocator.free(target_gpg_path);

    try prepareFilesystem(allocator, io, options, database_path, cache_path, target_gpg_path);

    var mounts = MountScope.init(allocator, io, options.root_path);
    defer mounts.deinit();
    try mounts.setup();

    const manager = try manager_module.Manager.init(allocator, environ, .{
        .config_path = options.config_path,
        .use_root = true,
        .root_directory = options.root_path,
        .database_path = database_path,
        .cache_directory = cache_path,
        .log_file = log_path,
        .gpg_directory = target_gpg_path,
    });
    defer manager.deinit();

    // The configured hook directories belong to the host. Loading them while
    // creating an empty root can run host-specific pre-transaction hooks (for
    // example snap-pac or boot-loader hooks) inside a root where their
    // executables do not exist yet. A freshly provisioned root has no prior
    // transaction hooks of its own, so suppress hooks for this initial install.
    // Hooks shipped by the installed packages remain available to subsequent
    // package operations in the completed root.
    manager.disable_transaction_hooks();

    var diagnostic_output: DiagnosticOutput = undefined;
    if (diagnostic_writer) |writer| {
        diagnostic_output = .{ .stderr = writer };
        _ = try manager.dispatcher.addErrorHandler(.{
            .function = DiagnosticOutput.handleError,
            .data = &diagnostic_output,
        });
        _ = try manager.dispatcher.addScriptletHandler(.{
            .function = DiagnosticOutput.handleScriptlet,
            .data = &diagnostic_output,
        });
    }

    try manager.sync(false);
    var package_names = try allocator.alloc([:0]const u8, options.packages.len);
    defer allocator.free(package_names);
    var initialized: usize = 0;
    defer for (package_names[0..initialized]) |name| allocator.free(name);
    for (options.packages, package_names) |name, *owned_name| {
        if (!validPackageTarget(name)) return error.InvalidPackageTarget;
        owned_name.* = try allocator.dupeZ(u8, name);
        initialized += 1;
    }
    try manager.install_packages(package_names, .{ .needed = true });

    const installed = try manager.get_installed_packages();
    defer {
        for (installed) |*package| package.deinit(allocator);
        allocator.free(installed);
    }
    if (installed.len == 0) return error.EmptyBootstrapRoot;
    try requireFile(io, allocator, options.root_path, "usr/bin/bash");
    try requireDirectory(io, allocator, options.root_path, "var/lib/pacman/local");
    try finalizeRoot(allocator, io, environ, options.root_path, diagnostic_writer);
    try requireFile(io, allocator, options.root_path, "etc/ld.so.cache");
    try requireFile(io, allocator, options.root_path, "etc/passwd");
    try requireDirectory(io, allocator, options.root_path, "var/tmp");
    try requireFile(io, allocator, options.root_path, "etc/ssl/certs/ca-certificates.crt");
    return .{ .installed_package_count = installed.len };
}

fn validateRoot(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(root_path) or std.mem.eql(u8, root_path, "/"))
        return error.InvalidBootstrapRoot;
    const resolved = try std.fs.path.resolve(allocator, &.{root_path});
    defer allocator.free(resolved);
    if (!std.mem.eql(u8, resolved, std.mem.trimEnd(u8, root_path, "/")))
        return error.InvalidBootstrapRoot;
    const marker = try rootJoin(allocator, root_path, marker_name);
    defer allocator.free(marker);
    const stat = std.Io.Dir.cwd().statFile(io, marker, .{ .follow_symlinks = false }) catch
        return error.UnmanagedBootstrapRoot;
    if (stat.kind != .file) return error.UnmanagedBootstrapRoot;
}

fn validPackageTarget(value: []const u8) bool {
    if (value.len == 0 or value[0] == '-') return false;
    return std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn prepareFilesystem(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    database_path: []const u8,
    cache_path: []const u8,
    target_gpg_path: []const u8,
) !void {
    const directories = [_][]const u8{
        "etc/pacman.d", "var/lib/pacman", "var/cache/pacman/pkg", "var/log",
        "proc",         "sys",            "dev",                  "run",
        "tmp",
    };
    for (directories) |relative| {
        const path = try rootJoin(allocator, options.root_path, relative);
        defer allocator.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
    }
    const temporary_path = try rootJoin(allocator, options.root_path, "tmp");
    defer allocator.free(temporary_path);
    try std.Io.Dir.cwd().setFilePermissions(io, temporary_path, .fromMode(0o1777), .{});
    try std.Io.Dir.cwd().createDirPath(io, database_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);

    const target_config = try rootJoin(allocator, options.root_path, "etc/pacman.conf");
    defer allocator.free(target_config);
    try std.Io.Dir.copyFile(.cwd(), options.config_path, .cwd(), target_config, io, .{});

    const host_mirrorlist = "/etc/pacman.d/mirrorlist";
    if (std.Io.Dir.cwd().statFile(io, host_mirrorlist, .{})) |_| {
        const target_mirrorlist = try rootJoin(allocator, options.root_path, "etc/pacman.d/mirrorlist");
        defer allocator.free(target_mirrorlist);
        try std.Io.Dir.copyFile(.cwd(), host_mirrorlist, .cwd(), target_mirrorlist, io, .{});
    } else |_| {}

    try copyTree(allocator, io, options.host_gpg_directory, target_gpg_path);
    try std.Io.Dir.cwd().setFilePermissions(io, target_gpg_path, .fromMode(0o700), .{});
}

fn copyTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    var source = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source.close(io);
    try std.Io.Dir.cwd().createDirPath(io, destination_path);
    const source_stat = try std.Io.Dir.cwd().statFile(io, source_path, .{});
    try std.Io.Dir.cwd().setFilePermissions(io, destination_path, source_stat.permissions, .{});
    var walker = try source.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const destination = try std.fs.path.join(allocator, &.{ destination_path, entry.path });
        defer allocator.free(destination);
        switch (entry.kind) {
            .directory => {
                try std.Io.Dir.cwd().createDirPath(io, destination);
                const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
                try std.Io.Dir.cwd().setFilePermissions(io, destination, stat.permissions, .{});
            },
            .file => try std.Io.Dir.copyFile(source, entry.path, .cwd(), destination, io, .{ .make_path = true }),
            .sym_link => {
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target_len = try entry.dir.readLink(io, entry.basename, &target_buffer);
                try std.Io.Dir.cwd().symLink(io, target_buffer[0..target_len], destination, .{});
            },
            else => {},
        }
    }
}

const MountScope = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    mounted_paths: std.ArrayList([:0]u8) = .empty,

    fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) MountScope {
        return .{ .allocator = allocator, .io = io, .root_path = root_path };
    }

    fn setup(self: *MountScope) !void {
        try self.mount("proc", "proc", "proc", std.os.linux.MS.NOSUID | std.os.linux.MS.NOEXEC | std.os.linux.MS.NODEV, "");
        try self.mount("sys", "sysfs", "sysfs", std.os.linux.MS.NOSUID | std.os.linux.MS.NOEXEC | std.os.linux.MS.NODEV | std.os.linux.MS.RDONLY, "");
        try self.mount("dev", "udev", "devtmpfs", std.os.linux.MS.NOSUID, "mode=0755");

        const pts = try rootJoin(self.allocator, self.root_path, "dev/pts");
        defer self.allocator.free(pts);
        const shm = try rootJoin(self.allocator, self.root_path, "dev/shm");
        defer self.allocator.free(shm);
        try std.Io.Dir.cwd().createDirPath(self.io, pts);
        try std.Io.Dir.cwd().createDirPath(self.io, shm);
        try self.mount("dev/pts", "devpts", "devpts", std.os.linux.MS.NOSUID | std.os.linux.MS.NOEXEC, "mode=0620,gid=5");
        try self.mount("dev/shm", "shm", "tmpfs", std.os.linux.MS.NOSUID | std.os.linux.MS.NODEV, "mode=1777");
        try self.mount("run", "run", "tmpfs", std.os.linux.MS.NOSUID | std.os.linux.MS.NODEV, "mode=0755");
        try self.mount("tmp", "tmp", "tmpfs", std.os.linux.MS.NOSUID | std.os.linux.MS.NODEV | std.os.linux.MS.STRICTATIME, "mode=1777");
    }

    fn mount(
        self: *MountScope,
        relative: []const u8,
        special: [:0]const u8,
        filesystem: [:0]const u8,
        flags: u32,
        data: [:0]const u8,
    ) !void {
        const path = try rootJoinSentinel(self.allocator, self.root_path, relative);
        errdefer self.allocator.free(path);
        const result = std.os.linux.mount(
            special.ptr,
            path.ptr,
            filesystem.ptr,
            flags,
            if (data.len == 0) 0 else @intFromPtr(data.ptr),
        );
        if (std.os.linux.errno(result) != .SUCCESS) return error.BootstrapMountFailed;
        try self.mounted_paths.append(self.allocator, path);
    }

    fn deinit(self: *MountScope) void {
        var index = self.mounted_paths.items.len;
        while (index > 0) {
            index -= 1;
            const path = self.mounted_paths.items[index];
            _ = std.os.linux.umount2(path.ptr, std.os.linux.MNT.DETACH);
            self.allocator.free(path);
        }
        self.mounted_paths.deinit(self.allocator);
    }
};

fn rootJoin(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, relative });
}

fn rootJoinSentinel(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ![:0]u8 {
    const path = try rootJoin(allocator, root, relative);
    defer allocator.free(path);
    return allocator.dupeZ(u8, path);
}

fn requireFile(io: std.Io, allocator: std.mem.Allocator, root: []const u8, relative: []const u8) !void {
    const path = try rootJoin(allocator, root, relative);
    defer allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.IncompleteBootstrapRoot;
}

fn requireDirectory(io: std.Io, allocator: std.mem.Allocator, root: []const u8, relative: []const u8) !void {
    const path = try rootJoin(allocator, root, relative);
    defer allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .directory) return error.IncompleteBootstrapRoot;
}

test "internal bootstrap arguments require a root, separator, and packages" {
    const parsed = try parseArguments(&.{
        "--root",   "/var/lib/shelly/build-roots/v1/operations/a/root",
        "--config", "/etc/pacman.conf",
        "--",       "base",
        "git",
    });
    try std.testing.expectEqualStrings("/var/lib/shelly/build-roots/v1/operations/a/root", parsed.root_path);
    try std.testing.expectEqualStrings("/etc/pacman.conf", parsed.config_path);
    try std.testing.expectEqual(@as(usize, 2), parsed.packages.len);
    try std.testing.expectError(error.InvalidBootstrapArguments, parseArguments(&.{ "--root", "/tmp/root" }));
    try std.testing.expectError(error.InvalidBootstrapArguments, parseArguments(&.{ "--root", "/tmp/root", "--" }));
}

test "bootstrap package targets reject option injection and line breaks" {
    try std.testing.expect(validPackageTarget("base-devel"));
    try std.testing.expect(validPackageTarget("core/linux"));
    try std.testing.expect(!validPackageTarget("--nodeps"));
    try std.testing.expect(!validPackageTarget("bad\nname"));
}

test "internal bootstrap diagnostics write libalpm failures only to stderr" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var diagnostics: DiagnosticOutput = .{ .stderr = &output.writer };

    DiagnosticOutput.handleError(&diagnostics, .{
        .message = "invalid or corrupted package (PGP signature)\n",
    });
    DiagnosticOutput.handleScriptlet(&diagnostics, .{
        .line = "a package scriptlet failed\n",
    });

    try std.testing.expectEqualStrings(
        "shellystrap: libalpm: invalid or corrupted package (PGP signature)\n" ++
            "shellystrap: scriptlet: a package scriptlet failed\n",
        output.written(),
    );
}

test "root finalizers use target binaries through chroot in stable order" {
    try std.testing.expectEqualStrings("ldconfig", root_finalizers[0].name);
    try std.testing.expectEqualStrings("systemd-sysusers", root_finalizers[1].name);
    try std.testing.expectEqualStrings("systemd-tmpfiles", root_finalizers[2].name);
    try std.testing.expectEqualStrings("update-ca-trust", root_finalizers[3].name);

    const argv = try rootFinalizerArguments(
        std.testing.allocator,
        "/var/lib/shelly/build-roots/v1/operations/a/root",
        root_finalizers[2],
    );
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{
            "/usr/bin/chroot",
            "/var/lib/shelly/build-roots/v1/operations/a/root",
            "/usr/bin/systemd-tmpfiles",
            "--create",
        },
        argv,
    );
}

test "root finalizer output is redirected to the diagnostic writer" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var context: FinalizerOutput = .{
        .writer = &output.writer,
        .name = "ldconfig",
    };
    FinalizerOutput.handle(&context, .stdout, "generated cache");
    FinalizerOutput.handle(&context, .stderr, "warning");
    reportFinalizerFailure(&output.writer, "update-ca-trust", "exited with status 7");
    try std.testing.expectEqualStrings(
        "shellystrap: ldconfig: generated cache\n" ++
            "shellystrap: ldconfig: warning\n" ++
            "shellystrap: update-ca-trust: exited with status 7\n",
        output.written(),
    );
}
