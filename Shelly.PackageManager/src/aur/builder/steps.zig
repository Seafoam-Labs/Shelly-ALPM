//! makepkg step execution: build-directory validation, build logging, and the
//! bash runner that executes PKGBUILD lifecycle functions with captured
//! environment, pkgver, and package metadata.

const std = @import("std");
const package_metadata = @import("../../pkgbuild/package_metadata.zig");
const events = @import("../events.zig");
const op_context = @import("operation_context");
const archive = @import("archive");
const process_runner = @import("../builder.zig");
const metadata = @import("metadata.zig");
const sandbox = @import("sandbox.zig");
const PackageBuilder = @import("builder.zig").PackageBuilder;
const ExecutionStep = @import("../../pkgbuild/pkgbuild_parser.zig").execution_step;

pub fn validateBuildDirectories(self: *PackageBuilder) !void {
    const cwd = std.Io.Dir.cwd();
    const start_stat = try cwd.statFile(self.io, self.options.start_directory, .{});
    if (start_stat.kind != .directory) return error.InvalidStartDirectory;

    for ([_][]const u8{
        self.options.work_directory,
        self.options.package_destination,
        self.options.source_destination,
        self.options.log_destination,
    }) |root| {
        cwd.createDirPath(self.io, root) catch {
            reportUnwritableBuildDirectory(self, root);
            return error.BuildDirectoryNotWritable;
        };
        try validateWritableDirectory(self, root);
    }

    for ([_][]const u8{ "src", "pkg", ".src.shelly-staging" }) |name| {
        const path = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, name });
        defer self.allocator.free(path);
        try validateWritableDirectory(self, path);
    }
}

fn validateWritableDirectory(self: *PackageBuilder, root_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(self.io, root_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) {
        reportUnwritableBuildDirectory(self, root_path);
        return error.BuildDirectoryNotWritable;
    }
    const mode = stat.permissions.toMode();
    if (mode & 0o222 == 0 or mode & 0o111 == 0) {
        reportUnwritableBuildDirectory(self, root_path);
        return error.BuildDirectoryNotWritable;
    }
    cwd.access(self.io, root_path, .{ .write = true, .execute = true }) catch {
        reportUnwritableBuildDirectory(self, root_path);
        return error.BuildDirectoryNotWritable;
    };
}

pub fn reportUnwritableBuildDirectory(self: *PackageBuilder, path: []const u8) void {
    const message = std.fmt.allocPrint(
        self.allocator,
        "Build directory is not writable by the non-root builder: {s}. Remove it or restore ownership to the invoking user.",
        .{path},
    ) catch return;
    defer self.allocator.free(message);
    if (self.active_operation) |operation|
        operation.reportError(error.BuildDirectoryNotWritable, message, "build", null, false);
}

pub fn openBuildLog(self: *PackageBuilder) !BuildLog {
    const package_base = self.package_builds[0].variables.get("pkgbase") orelse
        self.package_builds[0].pkg_name orelse self.requested_names[0];
    const normalized = try archive.normalizeEntryPath(self.allocator, package_base);
    defer self.allocator.free(normalized);
    if (std.mem.indexOfScalar(u8, normalized, '/') != null) return error.InvalidPackageBase;
    var random_suffix: [8]u8 = undefined;
    self.io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
    const path = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}-{d}-{s}.log",
        .{ self.options.log_destination, normalized, timestamp, suffix },
    );
    defer self.allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
    return .{ .file = file, .io = self.io };
}

pub fn logPhase(self: *PackageBuilder, name: []const u8) !void {
    if (self.active_log) |log| try log.writeRecord("phase", name);
}

pub fn runStep(
    self: *PackageBuilder,
    operation: *op_context.Operation,
    package_name: []const u8,
    step_name: []const u8,
    execution_prelude: []const u8,
    helper_definitions: []const u8,
    body: []const u8,
    working_directory: ?[]const u8,
) !void {
    try logPhase(self, step_name);
    self.failure_location = .{
        .package_name = package_name,
        .step_name = step_name,
    };
    try operation.checkCancelled();
    const package_step = isPackageStep(step_name);
    const capture_pkgver = std.mem.eql(u8, step_name, "pkgver");
    const capture_metadata = package_step;
    const executable_body = try std.fmt.allocPrint(
        self.allocator,
        "{s}\n{s}\n{s}\ndeclare -- startdir=\"$4\"\ndeclare -- srcdir=\"$5\"\n{s}\n{s}\n{s}\ndeclare -- pkgver=\"$1\"\n__shelly_step() {{\n{s}\n}}\n{s}",
        .{
            if (package_step) virtualMetadataShellPrelude else "",
            if (package_step) package_metadata.shell_capture_prelude else "",
            execution_prelude,
            if (package_step) "declare -- pkgdir=\"$6\"" else "",
            messagingShellPrelude,
            helper_definitions,
            body,
            if (capture_pkgver) "__shelly_step > \"$2\"" else "__shelly_step",
        },
    );
    defer self.allocator.free(executable_body);

    const command_body = if (capture_metadata)
        try std.fmt.allocPrint(self.allocator, "{s}\n__shelly_capture_metadata > \"$3\"", .{executable_body})
    else
        try self.allocator.dupe(u8, executable_body);
    defer self.allocator.free(command_body);

    const srcdir = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, "src" },
    );
    defer self.allocator.free(srcdir);

    const pkgver_result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-pkgver" },
    );
    defer self.allocator.free(pkgver_result_path);
    const runtime_pkgdir = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, "pkg", package_name },
    );
    defer self.allocator.free(runtime_pkgdir);
    const metadata_result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-package-metadata" },
    );
    defer self.allocator.free(metadata_result_path);
    if (capture_pkgver) {
        std.Io.Dir.cwd().deleteFile(self.io, pkgver_result_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    defer if (capture_pkgver)
        std.Io.Dir.cwd().deleteFile(self.io, pkgver_result_path) catch {};
    if (capture_metadata) {
        std.Io.Dir.cwd().deleteFile(self.io, metadata_result_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    defer if (capture_metadata)
        std.Io.Dir.cwd().deleteFile(self.io, metadata_result_path) catch {};

    const current_pkgver = self.package_builds[0].pkg_version orelse "";
    const runtime_startdir = self.options.start_directory;
    const runtime_working_directory = working_directory orelse srcdir;

    var stream_context: StepStreamContext = .{
        .operation = operation,
        .package_name = package_name,
        .log = self.active_log,
    };
    const effective_options = try metadata.effectivePackageOptions(
        self.allocator,
        self.shellybuild_config.package.options,
        self.package_builds[0].options orelse &.{},
    );
    defer metadata.freeOwnedStrings(self.allocator, effective_options);
    const step_argv: []const []const u8 = &.{ "/bin/bash", "-e", "-c", command_body, "shelly-step", current_pkgver, pkgver_result_path, metadata_result_path, runtime_startdir, srcdir, runtime_pkgdir };
    const sandbox_enabled = self.shellybuild_config.sandbox.enabled;
    const wrapped = if (sandbox_enabled) try wrapStepCommand(self, step_argv) else null;
    defer if (wrapped) |command| command.deinit(self.allocator);
    const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
        self.allocator,
        self.io,
        self.environ,
        buildEnvironment(self, effective_options),
        if (wrapped) |command| command.argv else step_argv,
        runtime_working_directory,
        null,
        .{ .function = forwardStepLine, .data = &stream_context },
        operation,
    );
    if (self.active_log) |log| try log.ensureHealthy();
    if (package_step and exit_code == virtual_metadata_rejected_exit_code)
        return error.PrivilegedPackageOperationUnsupported;
    if (exit_code != 0) {
        if (sandbox_enabled) writeSandboxFailureHint(self);
        return error.StepFailed;
    }
    if (capture_pkgver) {
        const output = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            pkgver_result_path,
            self.allocator,
            .limited(64 * 1024),
        );
        defer self.allocator.free(output);
        try applyDynamicPkgver(self, output);
    }
    if (capture_metadata) {
        const output = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            metadata_result_path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(output);
        try metadata.applyPackageMetadata(self, package_name, output);
    }
    operation.status(.information, step_name, "aur_build_output", @intFromEnum(events.EventType.aur_build_output));
}

const WrappedStepCommand = struct {
    argv: [][]const u8,
    executable: ?[:0]u8,

    fn deinit(self: WrappedStepCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        if (self.executable) |path| allocator.free(path);
    }
};

/// Wraps the step argv in the Landlock sandbox wrapper. The wrapper receives
/// only the per-build paths; the fixed base allow-list is applied by the
/// wrapper entry point itself.
fn wrapStepCommand(self: *PackageBuilder, child_argv: []const []const u8) !WrappedStepCommand {
    var executable: ?[:0]u8 = null;
    errdefer if (executable) |path| self.allocator.free(path);
    var prefix_storage: [2][]const u8 = undefined;
    const wrapper_prefix: []const []const u8 = if (self.options.sandbox_wrapper_prefix) |prefix|
        prefix
    else blk: {
        const path = try std.process.executablePathAlloc(self.io, self.allocator);
        executable = path;
        prefix_storage = .{ path, sandbox.wrapper_argument };
        break :blk &prefix_storage;
    };

    const sandbox_config = self.shellybuild_config.sandbox;
    var read_write: std.ArrayList([]const u8) = .empty;
    defer read_write.deinit(self.allocator);
    try read_write.append(self.allocator, self.options.work_directory);
    try read_write.append(self.allocator, self.options.start_directory);
    for (sandbox_config.extra_write) |path|
        try read_write.append(self.allocator, path);

    const argv = try sandbox.buildWrappedCommand(
        self.allocator,
        wrapper_prefix,
        read_write.items,
        sandbox_config.extra_read,
        child_argv,
    );
    return .{ .argv = argv, .executable = executable };
}

/// Evaluates the top-level command-substitution assignments recorded by the
/// static parser. Each assignment's original statement runs in a sandboxed
/// bash child (post-review, confined exactly like lifecycle steps), then the
/// resulting values are read back. Returns a name -> value map used to seed the
/// resolution re-parse. Mirrors the pkgver() capture pattern in `runStep`.
pub fn evaluateDynamicAssignments(
    self: *PackageBuilder,
    operation: *op_context.Operation,
) !std.StringHashMap([]const u8) {
    const package_build = &self.package_builds[0];
    const dynamic = package_build.dynamic_assignments;
    const execution = package_build.execution orelse return error.MissingExecutionSteps;

    var result: std.StringHashMap([]const u8) = .init(self.allocator);
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }

    var script: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer script.deinit();
    const script_writer = &script.writer;
    try script_writer.writeAll(execution.shared_prelude);
    try script_writer.writeAll("\n");
    for (dynamic) |assignment| {
        try script_writer.writeAll(assignment.statement);
        try script_writer.writeAll("\n");
    }
    try script_writer.writeAll("printf '%s\\0'");
    for (dynamic) |assignment| {
        try script_writer.print(" \"${s}\"", .{assignment.name});
    }
    try script_writer.writeAll(" > \"$1\"\n");
    const command_body = try script.toOwnedSlice();
    defer self.allocator.free(command_body);

    const result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-dynamic-vars" },
    );
    defer self.allocator.free(result_path);
    std.Io.Dir.cwd().deleteFile(self.io, result_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(self.io, result_path) catch {};

    try logPhase(self, "dynamic-assignments");
    try operation.checkCancelled();
    self.failure_location = .{
        .package_name = package_build.pkg_name,
        .step_name = "dynamic-assignments",
    };

    var stream_context: StepStreamContext = .{
        .operation = operation,
        .package_name = self.requested_names[0],
        .log = self.active_log,
    };
    const effective_options = try metadata.effectivePackageOptions(
        self.allocator,
        self.shellybuild_config.package.options,
        package_build.options orelse &.{},
    );
    defer metadata.freeOwnedStrings(self.allocator, effective_options);
    const step_argv: []const []const u8 = &.{ "/bin/bash", "-e", "-c", command_body, "shelly-dynamic", result_path };
    const sandbox_enabled = self.shellybuild_config.sandbox.enabled;
    const wrapped = if (sandbox_enabled) try wrapStepCommand(self, step_argv) else null;
    defer if (wrapped) |command| command.deinit(self.allocator);
    const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
        self.allocator,
        self.io,
        self.environ,
        buildEnvironment(self, effective_options),
        if (wrapped) |command| command.argv else step_argv,
        self.options.work_directory,
        null,
        .{ .function = forwardStepLine, .data = &stream_context },
        operation,
    );
    if (self.active_log) |log| try log.ensureHealthy();
    if (exit_code != 0) {
        if (sandbox_enabled) writeSandboxFailureHint(self);
        return error.StepFailed;
    }

    const output = try std.Io.Dir.cwd().readFileAlloc(
        self.io,
        result_path,
        self.allocator,
        .limited(1024 * 1024),
    );
    defer self.allocator.free(output);
    var values = std.mem.splitScalar(u8, output, 0);
    for (dynamic) |assignment| {
        const value = values.next() orelse return error.StepFailed;
        const key_owned = try self.allocator.dupe(u8, assignment.name);
        const value_owned = try self.allocator.dupe(u8, value);
        result.put(key_owned, value_owned) catch |err| {
            self.allocator.free(key_owned);
            self.allocator.free(value_owned);
            return err;
        };
    }
    return result;
}

fn writeSandboxFailureHint(self: *const PackageBuilder) void {
    const log = self.active_log orelse return;
    log.writeRecord(
        "sandbox",
        "step failed inside the Landlock sandbox; if it hit a permission error, grant additional paths through [sandbox] extra_read or extra_write",
    ) catch {};
}

pub fn buildEnvironment(
    self: *const PackageBuilder,
    effective_options: []const []u8,
) process_runner.BuildEnvironment {
    const buildflags = !metadata.optionExplicitlyDisabled(effective_options, "buildflags");
    const makeflags = !metadata.optionExplicitlyDisabled(effective_options, "makeflags");
    const lto = buildflags and !metadata.optionExplicitlyDisabled(effective_options, "lto");
    return .{
        .cppflags = if (buildflags) self.shellybuild_config.build.cppflags else null,
        .cflags = if (buildflags) self.shellybuild_config.build.cflags else null,
        .cxxflags = if (buildflags) self.shellybuild_config.build.cxxflags else null,
        .ldflags = if (buildflags) self.shellybuild_config.build.ldflags else null,
        .ltoflags = if (lto) self.shellybuild_config.build.ltoflags else null,
        .makeflags = if (makeflags) self.shellybuild_config.build.makeflags else null,
        .chost = self.shellybuild_config.build.chost,
        .distcc_hosts = if (self.shellybuild_config.build.distcc)
            self.shellybuild_config.build.distcc_hosts
        else
            null,
        .ccache = self.shellybuild_config.build.ccache,
        .distcc = self.shellybuild_config.build.distcc,
    };
}

fn applyDynamicPkgver(self: *PackageBuilder, output: []const u8) !void {
    const version = std.mem.trimEnd(u8, output, "\r\n");
    try metadata.validatePkgver(version);

    for (self.package_builds) |*package_build| {
        const owned_version = try self.allocator.dupe(u8, version);
        if (package_build.pkg_version) |old| self.allocator.free(old);
        package_build.pkg_version = owned_version;

        const map_value = try self.allocator.dupe(u8, version);
        if (package_build.variables.fetchRemove("pkgver")) |old| {
            self.allocator.free(old.value);
            package_build.variables.put(old.key, map_value) catch |err| {
                self.allocator.free(old.key);
                self.allocator.free(map_value);
                return err;
            };
        } else {
            const map_key = try self.allocator.dupe(u8, "pkgver");
            package_build.variables.put(map_key, map_value) catch |err| {
                self.allocator.free(map_key);
                self.allocator.free(map_value);
                return err;
            };
        }
    }
}

pub const BuildLog = struct {
    file: std.Io.File,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    failed: std.atomic.Value(bool) = .init(false),

    pub fn writeRecord(self: *BuildLog, kind: []const u8, message: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.file.writeStreamingAll(self.io, "[");
        try self.file.writeStreamingAll(self.io, kind);
        try self.file.writeStreamingAll(self.io, "] ");
        try self.file.writeStreamingAll(self.io, message);
        try self.file.writeStreamingAll(self.io, "\n");
        try self.file.sync(self.io);
    }

    pub fn writeStream(self: *BuildLog, stream: process_runner.StreamKind, line: []const u8) void {
        self.writeRecord(if (stream == .stderr) "stderr" else "stdout", line) catch
            self.failed.store(true, .release);
    }

    pub fn ensureHealthy(self: *const BuildLog) !void {
        if (self.failed.load(.acquire)) return error.BuildLogWriteFailed;
    }

    pub fn close(self: *BuildLog) void {
        self.file.close(self.io);
    }
};

const virtual_metadata_rejected_exit_code: u8 = 97;

/// makepkg messaging helpers (util/message.sh). PKGBUILDs call these from any
/// lifecycle function; step output is piped, so colors stay off like makepkg
/// does for non-terminal output. Defined before PKGBUILD helpers so a
/// PKGBUILD that ships its own definitions keeps overriding them.
const messagingShellPrelude =
    \\msg() {
    \\  local mesg=$1; shift
    \\  printf "==> ${mesg}\n" "$@"
    \\}
    \\msg2() {
    \\  local mesg=$1; shift
    \\  printf "  -> ${mesg}\n" "$@"
    \\}
    \\plain() {
    \\  local mesg=$1; shift
    \\  printf "    ${mesg}\n" "$@"
    \\}
    \\plainerr() {
    \\  plain "$@" >&2
    \\}
    \\warning() {
    \\  local mesg=$1; shift
    \\  printf "==> WARNING: ${mesg}\n" "$@" >&2
    \\}
    \\error() {
    \\  local mesg=$1; shift
    \\  printf "==> ERROR: ${mesg}\n" "$@" >&2
    \\}
;

/// Bash functions used only for package() and package_<name>(). They simulate
/// the common fakeroot ownership operations without changing host ownership.
/// The archive writer independently records root ownership for every entry.
const virtualMetadataShellPrelude =
    \\__shelly_metadata_reject() {
    \\  printf '%s\n' 'shelly: unsupported privileged package metadata operation' >&2
    \\  return 97
    \\}
    \\mknod() {
    \\  printf '%s\n' 'shelly: package steps cannot create device nodes' >&2
    \\  return 1
    \\}
    \\__shelly_root_identity() {
    \\  case "$1" in
    \\    root|0|root:root|root:0|0:root|0:0) return 0 ;;
    \\    *) return 1 ;;
    \\  esac
    \\}
    \\chown() {
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -R|-h|-H|-L|-P|--recursive|--no-dereference|--dereference|--preserve-root) shift ;;
    \\      --) shift; break ;;
    \\      -*) __shelly_metadata_reject; return $? ;;
    \\      *) break ;;
    \\    esac
    \\  done
    \\  [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\  __shelly_root_identity "$1" || { __shelly_metadata_reject; return $?; }
    \\  return 0
    \\}
    \\chgrp() {
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -R|-h|-H|-L|-P|--recursive|--no-dereference|--dereference|--preserve-root) shift ;;
    \\      --) shift; break ;;
    \\      -*) __shelly_metadata_reject; return $? ;;
    \\      *) break ;;
    \\    esac
    \\  done
    \\  [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\  case "$1" in root|0) return 0 ;; *) __shelly_metadata_reject; return $? ;; esac
    \\}
    \\install() {
    \\  local -a shelly_install_args=()
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -o|--owner|-g|--group)
    \\        [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\        case "$2" in root|0) shift 2 ;; *) __shelly_metadata_reject; return $? ;; esac ;;
    \\      --owner=*|--group=*)
    \\        case "${1#*=}" in root|0) shift ;; *) __shelly_metadata_reject; return $? ;; esac ;;
    \\      *) shelly_install_args+=("$1"); shift ;;
    \\    esac
    \\  done
    \\  /usr/bin/install "${shelly_install_args[@]}"
    \\}
;

pub const StepStreamContext = struct {
    operation: *op_context.Operation,
    package_name: []const u8,
    log: ?*BuildLog,
};

pub fn forwardStepLine(data: ?*anyopaque, stream: process_runner.StreamKind, line: []const u8) void {
    const context: *StepStreamContext = @ptrCast(@alignCast(data.?));
    if (context.log) |log| log.writeStream(stream, line);
    const event_type: events.EventType = if (stream == .stderr) .aur_build_error else .aur_build_output;
    context.operation.status(
        if (stream == .stderr) .warning else .information,
        line,
        @tagName(event_type),
        @intFromEnum(event_type),
    );
    if (stream == .stdout) if (process_runner.parseBuildProgress(line)) |progress| {
        context.operation.progress(.{
            .stage = "makepkg_build",
            .percentage = @floatFromInt(progress.percent),
            .message = progress.message,
            .native_code = @intFromEnum(events.ProgressType.makepkg_build),
        });
    };
}

pub fn isPackageStep(name: []const u8) bool {
    return std.mem.eql(u8, name, "package") or std.mem.startsWith(u8, name, "package_");
}

pub fn findPackageStep(steps: []const ExecutionStep) ?*const ExecutionStep {
    for (steps) |*step| if (isPackageStep(step.name)) return step;
    return null;
}
