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
const virtual_ownership = @import("virtual_ownership.zig");
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
            if (package_step) "declare -- pkgdir=\"$6\"\ndeclare -r __shelly_virtual_ownership_log=\"$7\"" else "",
            messagingShellPrelude,
            helper_definitions,
            body,
            if (capture_pkgver) "__shelly_step > \"$2\"" else "__shelly_step",
        },
    );
    defer self.allocator.free(executable_body);

    const command_body = if (capture_metadata)
        try std.fmt.allocPrint(
            self.allocator,
            "{s}\n__shelly_capture_metadata > \"$3\"\nprintf 'E\\0' >> \"$__shelly_virtual_ownership_log\"",
            .{executable_body},
        )
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
    const ownership_result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-virtual-ownership" },
    );
    defer self.allocator.free(ownership_result_path);
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
    if (package_step) {
        std.Io.Dir.cwd().deleteFile(self.io, ownership_result_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var ownership_file = try std.Io.Dir.cwd().createFile(self.io, ownership_result_path, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        ownership_file.close(self.io);
    }
    defer if (package_step)
        std.Io.Dir.cwd().deleteFile(self.io, ownership_result_path) catch {};

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
    const step_argv: []const []const u8 = &.{ "/bin/bash", "-e", "-c", command_body, "shelly-step", current_pkgver, pkgver_result_path, metadata_result_path, runtime_startdir, srcdir, runtime_pkgdir, ownership_result_path };
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
    if (package_step) {
        self.clearVirtualOwnership();
        self.virtual_ownership_tracker = virtual_ownership.Tracker.readJournal(
            self.allocator,
            self.io,
            ownership_result_path,
            runtime_pkgdir,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PrivilegedPackageOperationUnsupported,
        };
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

pub const DynamicArrayOverrides = std.StringHashMap([]const []const u8);
pub const DynamicScalarUnsets = std.StringHashMap(void);
pub const DynamicArrayUnsets = std.StringHashMap(void);

pub const ShellOptionDelta = struct {
    shell_enable: [][]const u8,
    shell_disable: [][]const u8,
    shopt_enable: [][]const u8,
    shopt_disable: [][]const u8,

    pub fn deinit(self: *ShellOptionDelta, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.shell_enable);
        freeOwnedStrings(allocator, self.shell_disable);
        freeOwnedStrings(allocator, self.shopt_enable);
        freeOwnedStrings(allocator, self.shopt_disable);
        self.* = undefined;
    }

    pub fn isEmpty(self: ShellOptionDelta) bool {
        return self.shell_enable.len == 0 and self.shell_disable.len == 0 and
            self.shopt_enable.len == 0 and self.shopt_disable.len == 0;
    }
};

pub const DynamicMetadataOverrides = struct {
    scalars: std.StringHashMap([]const u8),
    unset_scalars: DynamicScalarUnsets,
    arrays: DynamicArrayOverrides,
    unset_arrays: DynamicArrayUnsets,
    shell_options: ShellOptionDelta,

    pub fn deinit(self: *DynamicMetadataOverrides, allocator: std.mem.Allocator) void {
        deinitDynamicScalarOverrides(allocator, &self.scalars);
        deinitDynamicScalarUnsets(allocator, &self.unset_scalars);
        deinitDynamicArrayOverrides(allocator, &self.arrays);
        deinitDynamicArrayUnsets(allocator, &self.unset_arrays);
        self.shell_options.deinit(allocator);
        self.* = undefined;
    }
};

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn deinitDynamicScalarOverrides(
    allocator: std.mem.Allocator,
    overrides: *std.StringHashMap([]const u8),
) void {
    var iterator = overrides.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    overrides.deinit();
}

pub fn deinitDynamicScalarUnsets(
    allocator: std.mem.Allocator,
    unsets: *DynamicScalarUnsets,
) void {
    var iterator = unsets.keyIterator();
    while (iterator.next()) |name| allocator.free(name.*);
    unsets.deinit();
}

pub fn deinitDynamicArrayOverrides(
    allocator: std.mem.Allocator,
    overrides: *DynamicArrayOverrides,
) void {
    var iterator = overrides.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        for (entry.value_ptr.*) |item| allocator.free(item);
        allocator.free(entry.value_ptr.*);
    }
    overrides.deinit();
}

pub fn deinitDynamicArrayUnsets(
    allocator: std.mem.Allocator,
    unsets: *DynamicArrayUnsets,
) void {
    var iterator = unsets.keyIterator();
    while (iterator.next()) |name| allocator.free(name.*);
    unsets.deinit();
}

fn isShellVariableName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isShellOptionName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '-'))
            return false;
    }
    return true;
}

fn parseShellOptionList(allocator: std.mem.Allocator, value: []const u8) ![][]const u8 {
    if (value.len > 64 * 1024) return error.InvalidDynamicShellOptionOutput;
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }
    if (value.len == 0) return result.toOwnedSlice(allocator);

    var components = std.mem.splitScalar(u8, value, ':');
    while (components.next()) |component| {
        if (!isShellOptionName(component) or result.items.len >= 256)
            return error.InvalidDynamicShellOptionOutput;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing, component))
                return error.InvalidDynamicShellOptionOutput;
        }
        const owned = try allocator.dupe(u8, component);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
    return result.toOwnedSlice(allocator);
}

fn containsShellOption(options: []const []const u8, name: []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, option, name)) return true;
    return false;
}

fn shellOptionDifference(
    allocator: std.mem.Allocator,
    minuend: []const []const u8,
    subtrahend: []const []const u8,
) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }
    for (minuend) |option| {
        if (containsShellOption(subtrahend, option)) continue;
        const owned = try allocator.dupe(u8, option);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
    return result.toOwnedSlice(allocator);
}

fn parseShellOptionDelta(allocator: std.mem.Allocator, output: []const u8) !ShellOptionDelta {
    var fields = std.mem.splitScalar(u8, output, 0);
    const before_shopt_text = fields.next() orelse return error.InvalidDynamicShellOptionOutput;
    const after_shopt_text = fields.next() orelse return error.InvalidDynamicShellOptionOutput;
    const before_shell_text = fields.next() orelse return error.InvalidDynamicShellOptionOutput;
    const after_shell_text = fields.next() orelse return error.InvalidDynamicShellOptionOutput;
    const terminator = fields.next() orelse return error.InvalidDynamicShellOptionOutput;
    if (terminator.len != 0 or fields.next() != null)
        return error.InvalidDynamicShellOptionOutput;

    const before_shopt = try parseShellOptionList(allocator, before_shopt_text);
    defer freeOwnedStrings(allocator, before_shopt);
    const after_shopt = try parseShellOptionList(allocator, after_shopt_text);
    defer freeOwnedStrings(allocator, after_shopt);
    const before_shell = try parseShellOptionList(allocator, before_shell_text);
    defer freeOwnedStrings(allocator, before_shell);
    const after_shell = try parseShellOptionList(allocator, after_shell_text);
    defer freeOwnedStrings(allocator, after_shell);

    const shell_enable = try shellOptionDifference(allocator, after_shell, before_shell);
    errdefer freeOwnedStrings(allocator, shell_enable);
    const shell_disable = try shellOptionDifference(allocator, before_shell, after_shell);
    errdefer freeOwnedStrings(allocator, shell_disable);
    const shopt_enable = try shellOptionDifference(allocator, after_shopt, before_shopt);
    errdefer freeOwnedStrings(allocator, shopt_enable);
    const shopt_disable = try shellOptionDifference(allocator, before_shopt, after_shopt);
    errdefer freeOwnedStrings(allocator, shopt_disable);
    return .{
        .shell_enable = shell_enable,
        .shell_disable = shell_disable,
        .shopt_enable = shopt_enable,
        .shopt_disable = shopt_disable,
    };
}

fn parseDynamicScalarOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
) !struct { values: std.StringHashMap([]const u8), unsets: DynamicScalarUnsets } {
    var values: std.StringHashMap([]const u8) = .init(allocator);
    errdefer deinitDynamicScalarOverrides(allocator, &values);
    var unsets: DynamicScalarUnsets = .init(allocator);
    errdefer deinitDynamicScalarUnsets(allocator, &unsets);

    var fields = std.mem.splitScalar(u8, output, 0);
    while (true) {
        const kind = fields.next() orelse return error.InvalidDynamicScalarOutput;
        if (kind.len == 0) {
            if (fields.next() != null) return error.InvalidDynamicScalarOutput;
            break;
        }
        const name = fields.next() orelse return error.InvalidDynamicScalarOutput;
        if (!isShellVariableName(name) or values.contains(name) or unsets.contains(name))
            return error.InvalidDynamicScalarOutput;
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        if (std.mem.eql(u8, kind, "S")) {
            const value = fields.next() orelse return error.InvalidDynamicScalarOutput;
            const owned_value = try allocator.dupe(u8, value);
            errdefer allocator.free(owned_value);
            try values.put(key, owned_value);
        } else if (std.mem.eql(u8, kind, "U")) {
            try unsets.put(key, {});
        } else {
            return error.InvalidDynamicScalarOutput;
        }
    }
    return .{ .values = values, .unsets = unsets };
}

const dynamic_scalar_capture_prelude =
    \\declare -A __shelly_before_scalars=()
    \\__shelly_ignore_scalar() {
    \\  case "$1" in
    \\    __shelly_*|BASH_*|BASHOPTS|BASHPID|EPOCHREALTIME|EPOCHSECONDS|LINENO|OLDPWD|OPTARG|OPTIND|PIPESTATUS|PPID|PWD|RANDOM|SECONDS|SHELLOPTS|SHLVL|SRANDOM|_) return 0 ;;
    \\  esac
    \\  return 1
    \\}
    \\__shelly_scalar_declaration() {
    \\  local __shelly_name="$1" __shelly_declaration __shelly_attributes
    \\  __shelly_declaration=$(declare -p "$__shelly_name" 2>/dev/null) || return 1
    \\  __shelly_attributes=${__shelly_declaration#declare }
    \\  __shelly_attributes=${__shelly_attributes%% *}
    \\  case "$__shelly_attributes" in *a*|*A*|*n*) return 1 ;; esac
    \\  printf '%s' "$__shelly_declaration"
    \\}
    \\__shelly_snapshot_scalars() {
    \\  local __shelly_name __shelly_declaration
    \\  while IFS= read -r __shelly_name; do
    \\    __shelly_ignore_scalar "$__shelly_name" && continue
    \\    __shelly_declaration=$(__shelly_scalar_declaration "$__shelly_name") || continue
    \\    __shelly_before_scalars["$__shelly_name"]="$__shelly_declaration"
    \\  done < <(compgen -A variable)
    \\}
    \\__shelly_capture_scalar_changes() {
    \\  local __shelly_path="$1" __shelly_name __shelly_declaration
    \\  local -A __shelly_after_scalars=()
    \\  : > "$__shelly_path"
    \\  while IFS= read -r __shelly_name; do
    \\    __shelly_ignore_scalar "$__shelly_name" && continue
    \\    __shelly_declaration=$(__shelly_scalar_declaration "$__shelly_name") || continue
    \\    __shelly_after_scalars["$__shelly_name"]=1
    \\    if [[ ${__shelly_before_scalars[$__shelly_name]+present} != present || ${__shelly_before_scalars[$__shelly_name]} != "$__shelly_declaration" ]]; then
    \\      printf 'S\0%s\0%s\0' "$__shelly_name" "${!__shelly_name-}" >> "$__shelly_path"
    \\    fi
    \\  done < <(compgen -A variable)
    \\  for __shelly_name in "${!__shelly_before_scalars[@]}"; do
    \\    if [[ ${__shelly_after_scalars[$__shelly_name]+present} != present ]]; then
    \\      printf 'U\0%s\0' "$__shelly_name" >> "$__shelly_path"
    \\    fi
    \\  done
    \\}
    \\readonly -f __shelly_ignore_scalar __shelly_scalar_declaration __shelly_snapshot_scalars __shelly_capture_scalar_changes
;

const dynamic_array_capture_prelude =
    \\declare -A __shelly_before_arrays=()
    \\__shelly_ignore_array() {
    \\  case "$1" in
    \\    __shelly_*|BASH_*|BASHOPTS|BASHPID|EPOCHREALTIME|EPOCHSECONDS|LINENO|OLDPWD|OPTARG|OPTIND|PIPESTATUS|PPID|PWD|RANDOM|SECONDS|SHELLOPTS|SHLVL|SRANDOM|_) return 0 ;;
    \\  esac
    \\  return 1
    \\}
    \\__shelly_array_declaration() {
    \\  local __shelly_name="$1" __shelly_declaration __shelly_attributes
    \\  __shelly_declaration=$(declare -p "$__shelly_name" 2>/dev/null) || return 1
    \\  __shelly_attributes=${__shelly_declaration#declare }
    \\  __shelly_attributes=${__shelly_attributes%% *}
    \\  case "$__shelly_attributes" in
    \\    *A*|*n*) return 1 ;;
    \\    *a*) printf '%s' "$__shelly_declaration" ;;
    \\    *) return 1 ;;
    \\  esac
    \\}
    \\__shelly_snapshot_arrays() {
    \\  local __shelly_name __shelly_declaration
    \\  while IFS= read -r __shelly_name; do
    \\    __shelly_ignore_array "$__shelly_name" && continue
    \\    __shelly_declaration=$(__shelly_array_declaration "$__shelly_name") || continue
    \\    __shelly_before_arrays["$__shelly_name"]="$__shelly_declaration"
    \\  done < <(compgen -A variable)
    \\}
    \\__shelly_clear_user_arrays() {
    \\  local __shelly_name
    \\  while IFS= read -r __shelly_name; do
    \\    __shelly_ignore_array "$__shelly_name" && continue
    \\    __shelly_array_declaration "$__shelly_name" >/dev/null || continue
    \\    unset -v "$__shelly_name"
    \\  done < <(compgen -A variable)
    \\}
    \\__shelly_write_array_record() {
    \\  local __shelly_path="$1" __shelly_name="$2" __shelly_count
    \\  local -n __shelly_array_ref="$__shelly_name"
    \\  __shelly_count=${#__shelly_array_ref[@]}
    \\  if ((__shelly_count > 4096)); then
    \\    printf 'shelly: indexed array %s exceeds the 4096-element capture limit\n' "$__shelly_name" >&2
    \\    return 1
    \\  fi
    \\  printf 'A\0%s\0%s\0' "$__shelly_name" "$__shelly_count" >> "$__shelly_path"
    \\  if ((__shelly_count > 0)); then
    \\    printf '%s\0' "${__shelly_array_ref[@]}" >> "$__shelly_path"
    \\  fi
    \\}
    \\__shelly_capture_array_changes() {
    \\  local __shelly_path="$1" __shelly_name __shelly_declaration
    \\  local -A __shelly_after_arrays=()
    \\  : > "$__shelly_path"
    \\  while IFS= read -r __shelly_name; do
    \\    __shelly_ignore_array "$__shelly_name" && continue
    \\    __shelly_declaration=$(__shelly_array_declaration "$__shelly_name") || continue
    \\    __shelly_after_arrays["$__shelly_name"]=1
    \\    if [[ ${__shelly_before_arrays[$__shelly_name]+present} != present || ${__shelly_before_arrays[$__shelly_name]} != "$__shelly_declaration" ]]; then
    \\      __shelly_write_array_record "$__shelly_path" "$__shelly_name"
    \\    fi
    \\  done < <(compgen -A variable)
    \\  for __shelly_name in "${!__shelly_before_arrays[@]}"; do
    \\    if [[ ${__shelly_after_arrays[$__shelly_name]+present} != present ]]; then
    \\      printf 'U\0%s\0' "$__shelly_name" >> "$__shelly_path"
    \\    fi
    \\  done
    \\}
    \\readonly -f __shelly_ignore_array __shelly_array_declaration __shelly_snapshot_arrays __shelly_clear_user_arrays __shelly_write_array_record __shelly_capture_array_changes
;

fn parseDynamicArrayOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
) !struct { values: DynamicArrayOverrides, unsets: DynamicArrayUnsets } {
    var values: DynamicArrayOverrides = .init(allocator);
    errdefer deinitDynamicArrayOverrides(allocator, &values);
    var unsets: DynamicArrayUnsets = .init(allocator);
    errdefer deinitDynamicArrayUnsets(allocator, &unsets);
    var fields = std.mem.splitScalar(u8, output, 0);
    var record_count: usize = 0;
    while (true) {
        const kind = fields.next() orelse return error.InvalidDynamicArrayOutput;
        if (kind.len == 0) {
            if (fields.next() != null) return error.InvalidDynamicArrayOutput;
            break;
        }
        record_count += 1;
        if (record_count > 1024) return error.InvalidDynamicArrayOutput;
        const name = fields.next() orelse return error.InvalidDynamicArrayOutput;
        if (!isShellVariableName(name) or values.contains(name) or unsets.contains(name))
            return error.InvalidDynamicArrayOutput;
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        if (std.mem.eql(u8, kind, "U")) {
            try unsets.put(key, {});
            continue;
        }
        if (!std.mem.eql(u8, kind, "A")) return error.InvalidDynamicArrayOutput;
        const count_text = fields.next() orelse return error.InvalidDynamicArrayOutput;
        const count = std.fmt.parseInt(usize, count_text, 10) catch
            return error.InvalidDynamicArrayOutput;
        if (count > 4096) return error.InvalidDynamicArrayOutput;
        const items = try allocator.alloc([]const u8, count);
        var item_count: usize = 0;
        errdefer {
            for (items[0..item_count]) |item| allocator.free(item);
            allocator.free(items);
        }
        while (item_count < count) : (item_count += 1) {
            const value = fields.next() orelse return error.InvalidDynamicArrayOutput;
            items[item_count] = try allocator.dupe(u8, value);
        }
        try values.put(key, items);
    }
    return .{ .values = values, .unsets = unsets };
}

/// Sources the reviewed PKGBUILD in the same sandbox used for lifecycle steps
/// and captures one coherent snapshot of changed scalar and indexed-array
/// state. Sourcing preserves arbitrary top-level
/// parameter defaults, `if`, `case`, helper calls, and short-circuit control
/// flow; lifecycle functions are defined by Bash but are not invoked here.
pub fn evaluateDynamicMetadata(
    self: *PackageBuilder,
    operation: *op_context.Operation,
) !DynamicMetadataOverrides {
    const package_build = &self.package_builds[0];
    const execution = package_build.execution orelse return error.MissingExecutionSteps;

    var array_result: DynamicArrayOverrides = .init(self.allocator);
    errdefer deinitDynamicArrayOverrides(self.allocator, &array_result);
    var unset_array_result: DynamicArrayUnsets = .init(self.allocator);
    errdefer deinitDynamicArrayUnsets(self.allocator, &unset_array_result);
    var scalar_result: std.StringHashMap([]const u8) = .init(self.allocator);
    errdefer deinitDynamicScalarOverrides(self.allocator, &scalar_result);
    var unset_scalar_result: DynamicScalarUnsets = .init(self.allocator);
    errdefer deinitDynamicScalarUnsets(self.allocator, &unset_scalar_result);

    var script: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer script.deinit();
    const writer = &script.writer;
    try writer.writeAll(messagingShellPrelude);
    try writer.writeAll("\n");
    try writer.writeAll(execution.shared_prelude);
    try writer.writeAll("\n");
    try writer.writeAll(dynamic_scalar_capture_prelude);
    try writer.writeAll("\n");
    try writer.writeAll(dynamic_array_capture_prelude);
    try writer.writeAll(
        "\n__shelly_clear_user_arrays\n" ++
            "__shelly_snapshot_scalars\n" ++
            "__shelly_snapshot_arrays\n" ++
            "__shelly_before_bashopts=$BASHOPTS\n" ++
            "__shelly_before_shellopts=$SHELLOPTS\n" ++
            "source \"$4\"\n" ++
            "__shelly_capture_scalar_changes \"$1\"\n" ++
            "__shelly_capture_array_changes \"$2\"\n" ++
            "printf '%s\\0%s\\0%s\\0%s\\0' \"$__shelly_before_bashopts\" \"$BASHOPTS\" \"$__shelly_before_shellopts\" \"$SHELLOPTS\" > \"$3\"\n",
    );
    const command_body = try script.toOwnedSlice();
    defer self.allocator.free(command_body);

    const scalar_result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-dynamic-source-scalars" },
    );
    defer self.allocator.free(scalar_result_path);
    const array_result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-dynamic-source-arrays" },
    );
    defer self.allocator.free(array_result_path);
    const shell_option_result_path = try std.fs.path.join(
        self.allocator,
        &.{ self.options.work_directory, ".shelly-dynamic-shell-options" },
    );
    defer self.allocator.free(shell_option_result_path);
    std.Io.Dir.cwd().deleteFile(self.io, scalar_result_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(self.io, scalar_result_path) catch {};
    std.Io.Dir.cwd().deleteFile(self.io, array_result_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(self.io, array_result_path) catch {};
    std.Io.Dir.cwd().deleteFile(self.io, shell_option_result_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(self.io, shell_option_result_path) catch {};

    const pkgbuild_path = self.options.pkgbuild_path orelse
        return error.UnreviewedBuilderRequest;
    const canonical_pkgbuild_path = try std.Io.Dir.cwd().realPathFileAlloc(
        self.io,
        pkgbuild_path,
        self.allocator,
    );
    defer self.allocator.free(canonical_pkgbuild_path);

    try logPhase(self, "dynamic-metadata");
    try operation.checkCancelled();
    self.failure_location = .{
        .package_name = package_build.pkg_name,
        .step_name = "dynamic-metadata",
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
    const argv: []const []const u8 = &.{
        "/bin/bash",
        "-e",
        "-c",
        command_body,
        "shelly-dynamic-source",
        scalar_result_path,
        array_result_path,
        shell_option_result_path,
        canonical_pkgbuild_path,
    };
    const sandbox_enabled = self.shellybuild_config.sandbox.enabled;
    const wrapped = if (sandbox_enabled) try wrapStepCommand(self, argv) else null;
    defer if (wrapped) |command| command.deinit(self.allocator);
    const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
        self.allocator,
        self.io,
        self.environ,
        buildEnvironment(self, effective_options),
        if (wrapped) |command| command.argv else argv,
        self.options.start_directory,
        null,
        .{ .function = forwardStepLine, .data = &stream_context },
        operation,
    );
    if (self.active_log) |log| try log.ensureHealthy();
    if (exit_code != 0) {
        if (sandbox_enabled) writeSandboxFailureHint(self);
        return error.StepFailed;
    }

    const scalar_output = try std.Io.Dir.cwd().readFileAlloc(
        self.io,
        scalar_result_path,
        self.allocator,
        .limited(1024 * 1024),
    );
    defer self.allocator.free(scalar_output);
    const parsed_scalars = try parseDynamicScalarOutput(self.allocator, scalar_output);
    deinitDynamicScalarOverrides(self.allocator, &scalar_result);
    scalar_result = parsed_scalars.values;
    deinitDynamicScalarUnsets(self.allocator, &unset_scalar_result);
    unset_scalar_result = parsed_scalars.unsets;

    const array_output = try std.Io.Dir.cwd().readFileAlloc(
        self.io,
        array_result_path,
        self.allocator,
        .limited(1024 * 1024),
    );
    defer self.allocator.free(array_output);
    const parsed = try parseDynamicArrayOutput(self.allocator, array_output);
    deinitDynamicArrayOverrides(self.allocator, &array_result);
    array_result = parsed.values;
    deinitDynamicArrayUnsets(self.allocator, &unset_array_result);
    unset_array_result = parsed.unsets;

    const shell_option_output = try std.Io.Dir.cwd().readFileAlloc(
        self.io,
        shell_option_result_path,
        self.allocator,
        .limited(64 * 1024),
    );
    defer self.allocator.free(shell_option_output);
    var shell_options = try parseShellOptionDelta(self.allocator, shell_option_output);
    errdefer shell_options.deinit(self.allocator);
    return .{
        .scalars = scalar_result,
        .unset_scalars = unset_scalar_result,
        .arrays = array_result,
        .unset_arrays = unset_array_result,
        .shell_options = shell_options,
    };
}

test "dynamic scalar output preserves values, newlines, empty strings, and unsets" {
    var parsed = try parseDynamicScalarOutput(
        std.testing.allocator,
        "S\x00_scheduler\x00portable\x00" ++
            "S\x00_message\x00line one\nline two\x00" ++
            "S\x00_empty\x00\x00" ++
            "U\x00_removed\x00",
    );
    defer deinitDynamicScalarOverrides(std.testing.allocator, &parsed.values);
    defer deinitDynamicScalarUnsets(std.testing.allocator, &parsed.unsets);
    try std.testing.expectEqualStrings("portable", parsed.values.get("_scheduler").?);
    try std.testing.expectEqualStrings("line one\nline two", parsed.values.get("_message").?);
    try std.testing.expectEqualStrings("", parsed.values.get("_empty").?);
    try std.testing.expect(parsed.unsets.contains("_removed"));

    try std.testing.expectError(
        error.InvalidDynamicScalarOutput,
        parseDynamicScalarOutput(std.testing.allocator, "S\x00bad-name\x00value\x00"),
    );
    try std.testing.expectError(
        error.InvalidDynamicScalarOutput,
        parseDynamicScalarOutput(std.testing.allocator, "U\x00duplicate\x00S\x00duplicate\x00value\x00"),
    );
}

test "dynamic scalar capture separates validated shell option deltas" {
    var delta = try parseShellOptionDelta(
        std.testing.allocator,
        "checkwinsize:extquote\x00" ++
            "checkwinsize:extglob\x00" ++
            "braceexpand:hashall:interactive-comments\x00" ++
            "hashall:nounset\x00",
    );
    defer delta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), delta.shopt_enable.len);
    try std.testing.expectEqualStrings("extglob", delta.shopt_enable[0]);
    try std.testing.expectEqual(@as(usize, 1), delta.shopt_disable.len);
    try std.testing.expectEqualStrings("extquote", delta.shopt_disable[0]);
    try std.testing.expectEqual(@as(usize, 1), delta.shell_enable.len);
    try std.testing.expectEqualStrings("nounset", delta.shell_enable[0]);
    try std.testing.expectEqual(@as(usize, 2), delta.shell_disable.len);
    try std.testing.expectEqualStrings("braceexpand", delta.shell_disable[0]);
    try std.testing.expectEqualStrings("interactive-comments", delta.shell_disable[1]);

    var unchanged = try parseShellOptionDelta(
        std.testing.allocator,
        "extglob\x00extglob\x00hashall\x00hashall\x00",
    );
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expect(unchanged.isEmpty());

    try std.testing.expectError(
        error.InvalidDynamicShellOptionOutput,
        parseShellOptionDelta(std.testing.allocator, "extglob\x00extglob\x00hashall\x00hashall"),
    );
    try std.testing.expectError(
        error.InvalidDynamicShellOptionOutput,
        parseShellOptionDelta(std.testing.allocator, "extglob:bad$name\x00extglob\x00hashall\x00hashall\x00"),
    );
    try std.testing.expectError(
        error.InvalidDynamicShellOptionOutput,
        parseShellOptionDelta(std.testing.allocator, "extglob:extglob\x00extglob\x00hashall\x00hashall\x00"),
    );
}

test "dynamic indexed array output preserves values and unsets with structural bounds" {
    var valid = try parseDynamicArrayOutput(
        std.testing.allocator,
        "A\x00source\x002\x00one\x00\x00" ++
            "A\x00BUILD_FLAGS\x001\x00CC=clang\x00" ++
            "U\x00removed\x00",
    );
    defer deinitDynamicArrayOverrides(std.testing.allocator, &valid.values);
    defer deinitDynamicArrayUnsets(std.testing.allocator, &valid.unsets);
    try std.testing.expectEqual(@as(usize, 2), valid.values.get("source").?.len);
    try std.testing.expectEqualStrings("one", valid.values.get("source").?[0]);
    try std.testing.expectEqualStrings("", valid.values.get("source").?[1]);
    try std.testing.expectEqualStrings("CC=clang", valid.values.get("BUILD_FLAGS").?[0]);
    try std.testing.expect(valid.unsets.contains("removed"));

    try std.testing.expectError(
        error.InvalidDynamicArrayOutput,
        parseDynamicArrayOutput(std.testing.allocator, "A\x00source\x004097\x00"),
    );
    try std.testing.expectError(
        error.InvalidDynamicArrayOutput,
        parseDynamicArrayOutput(std.testing.allocator, "A\x00source\x002\x00one\x00"),
    );
    try std.testing.expectError(
        error.InvalidDynamicArrayOutput,
        parseDynamicArrayOutput(std.testing.allocator, "A\x00source\x00nope\x00"),
    );
    try std.testing.expectError(
        error.InvalidDynamicArrayOutput,
        parseDynamicArrayOutput(std.testing.allocator, "U\x00same\x00A\x00same\x000\x00"),
    );
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
        .source_date_epoch = self.source_date_epoch,
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
/// Supported requests are journaled against the target inode and later become
/// package/MTREE UID and GID metadata. Unsupported or malformed invocations
/// fail closed.
const virtualMetadataShellPrelude =
    \\__shelly_metadata_reject() {
    \\  printf '%s\n' 'shelly: unsupported privileged package metadata operation' >&2
    \\  return 97
    \\}
    \\mknod() {
    \\  printf '%s\n' 'shelly: package steps cannot create device nodes' >&2
    \\  return 1
    \\}
    \\__shelly_record_ownership() {
    \\  local __shelly_operation=$1 __shelly_specification=$2 __shelly_target=$3 __shelly_follow=${4:-1}
    \\  local __shelly_root __shelly_canonical __shelly_parent __shelly_identity __shelly_birth
    \\  __shelly_root=$(/usr/bin/realpath -e -- "$pkgdir") || { __shelly_metadata_reject; return $?; }
    \\  if [ "$__shelly_follow" -eq 1 ]; then
    \\    __shelly_canonical=$(/usr/bin/realpath -e -- "$__shelly_target") || { __shelly_metadata_reject; return $?; }
    \\  else
    \\    __shelly_parent=$(/usr/bin/realpath -e -- "$(/usr/bin/dirname -- "$__shelly_target")") || { __shelly_metadata_reject; return $?; }
    \\    __shelly_canonical="$__shelly_parent/$(/usr/bin/basename -- "$__shelly_target")"
    \\    [ -e "$__shelly_canonical" ] || [ -L "$__shelly_canonical" ] || { __shelly_metadata_reject; return $?; }
    \\  fi
    \\  case "$__shelly_canonical" in
    \\    "$__shelly_root"|"$__shelly_root"/*) ;;
    \\    *) __shelly_metadata_reject; return $? ;;
    \\  esac
    \\  if [ "$__shelly_follow" -eq 1 ]; then
    \\    __shelly_identity=$(/usr/bin/stat -Lc '%Hd:%Ld:%i:%.9W' -- "$__shelly_canonical") || { __shelly_metadata_reject; return $?; }
    \\  else
    \\    __shelly_identity=$(/usr/bin/stat -c '%Hd:%Ld:%i:%.9W' -- "$__shelly_canonical") || { __shelly_metadata_reject; return $?; }
    \\  fi
    \\  __shelly_birth=${__shelly_identity##*:}
    \\  [ "$__shelly_birth" != '0.000000000' ] || { __shelly_metadata_reject; return $?; }
    \\  printf '%s\0%s\0%s\0%s\0' "$__shelly_operation" "$__shelly_identity" "$__shelly_specification" "$__shelly_canonical" >> "$__shelly_virtual_ownership_log" || return 97
    \\}
    \\__shelly_record_ownership_recursive() {
    \\  local __shelly_operation=$1 __shelly_specification=$2 __shelly_target=$3 __shelly_follow=${4:-1}
    \\  local __shelly_canonical __shelly_entry __shelly_find_output
    \\  if [ "$__shelly_follow" -eq 0 ] && [ -L "$__shelly_target" ]; then
    \\    __shelly_record_ownership "$__shelly_operation" "$__shelly_specification" "$__shelly_target" 0
    \\    return $?
    \\  fi
    \\  __shelly_canonical=$(/usr/bin/realpath -e -- "$__shelly_target") || { __shelly_metadata_reject; return $?; }
    \\  if [ ! -d "$__shelly_canonical" ]; then
    \\    __shelly_record_ownership "$__shelly_operation" "$__shelly_specification" "$__shelly_canonical" "$__shelly_follow"
    \\    return $?
    \\  fi
    \\  __shelly_find_output=$(/usr/bin/mktemp "${__shelly_virtual_ownership_log}.find.XXXXXX") || { __shelly_metadata_reject; return $?; }
    \\  /usr/bin/find -P "$__shelly_canonical" -print0 > "$__shelly_find_output" || { /usr/bin/rm -f -- "$__shelly_find_output"; __shelly_metadata_reject; return $?; }
    \\  while IFS= read -r -d '' __shelly_entry; do
    \\    __shelly_record_ownership "$__shelly_operation" "$__shelly_specification" "$__shelly_entry" "$__shelly_follow" || { /usr/bin/rm -f -- "$__shelly_find_output"; return 97; }
    \\  done < "$__shelly_find_output"
    \\  /usr/bin/rm -f -- "$__shelly_find_output"
    \\}
    \\chown() {
    \\  local __shelly_recursive=0 __shelly_follow=1 __shelly_specification __shelly_target
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -R|--recursive) __shelly_recursive=1; shift ;;
    \\      -P|--preserve-root) shift ;;
    \\      -h|--no-dereference) __shelly_follow=0; shift ;;
    \\      --dereference) __shelly_follow=1; shift ;;
    \\      -H|-L|--from=*|--reference=*) __shelly_metadata_reject; return $? ;;
    \\      --) shift; break ;;
    \\      -*) __shelly_metadata_reject; return $? ;;
    \\      *) break ;;
    \\    esac
    \\  done
    \\  [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\  [ -n "$1" ] && [ "$1" != ':' ] || { __shelly_metadata_reject; return $?; }
    \\  __shelly_specification=$1; shift
    \\  for __shelly_target in "$@"; do
    \\    if [ "$__shelly_recursive" -eq 1 ]; then
    \\      __shelly_record_ownership_recursive C "$__shelly_specification" "$__shelly_target" "$__shelly_follow" || return $?
    \\    else
    \\      __shelly_record_ownership C "$__shelly_specification" "$__shelly_target" "$__shelly_follow" || return $?
    \\    fi
    \\  done
    \\  return 0
    \\}
    \\chgrp() {
    \\  local __shelly_recursive=0 __shelly_follow=1 __shelly_specification __shelly_target
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -R|--recursive) __shelly_recursive=1; shift ;;
    \\      -P|--preserve-root) shift ;;
    \\      -h|--no-dereference) __shelly_follow=0; shift ;;
    \\      --dereference) __shelly_follow=1; shift ;;
    \\      -H|-L|--from=*|--reference=*) __shelly_metadata_reject; return $? ;;
    \\      --) shift; break ;;
    \\      -*) __shelly_metadata_reject; return $? ;;
    \\      *) break ;;
    \\    esac
    \\  done
    \\  [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\  [ -n "$1" ] || { __shelly_metadata_reject; return $?; }
    \\  __shelly_specification=$1; shift
    \\  for __shelly_target in "$@"; do
    \\    if [ "$__shelly_recursive" -eq 1 ]; then
    \\      __shelly_record_ownership_recursive G "$__shelly_specification" "$__shelly_target" "$__shelly_follow" || return $?
    \\    else
    \\      __shelly_record_ownership G "$__shelly_specification" "$__shelly_target" "$__shelly_follow" || return $?
    \\    fi
    \\  done
    \\  return 0
    \\}
    \\install() {
    \\  local -a __shelly_install_args=() __shelly_operands=()
    \\  local __shelly_owner='' __shelly_group='' __shelly_have_owner=0 __shelly_have_group=0
    \\  local __shelly_directory_mode=0 __shelly_no_target_directory=0 __shelly_target_directory=''
    \\  local __shelly_ambiguous=0 __shelly_value __shelly_source __shelly_destination __shelly_target
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      --)
    \\        __shelly_install_args+=("$1"); shift
    \\        while [ "$#" -gt 0 ]; do __shelly_install_args+=("$1"); __shelly_operands+=("$1"); shift; done
    \\        break ;;
    \\      -o|--owner)
    \\        [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\        [ -n "$2" ] || { __shelly_metadata_reject; return $?; }
    \\        __shelly_owner=$2; __shelly_have_owner=1
    \\        shift 2 ;;
    \\      -g|--group)
    \\        [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\        [ -n "$2" ] || { __shelly_metadata_reject; return $?; }
    \\        __shelly_group=$2; __shelly_have_group=1
    \\        shift 2 ;;
    \\      --owner=*)
    \\        [ -n "${1#*=}" ] || { __shelly_metadata_reject; return $?; }
    \\        __shelly_owner=${1#*=}; __shelly_have_owner=1
    \\        shift ;;
    \\      --group=*)
    \\        [ -n "${1#*=}" ] || { __shelly_metadata_reject; return $?; }
    \\        __shelly_group=${1#*=}; __shelly_have_group=1
    \\        shift ;;
    \\      -o?*) __shelly_owner=${1:2}; __shelly_have_owner=1; shift ;;
    \\      -g?*) __shelly_group=${1:2}; __shelly_have_group=1; shift ;;
    \\      -m|--mode|-S|--suffix)
    \\        [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\        __shelly_install_args+=("$1" "$2"); shift 2 ;;
    \\      -t|--target-directory)
    \\        [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\        __shelly_target_directory=$2
    \\        __shelly_install_args+=("$1" "$2"); shift 2 ;;
    \\      --target-directory=*)
    \\        __shelly_target_directory=${1#*=}; __shelly_install_args+=("$1"); shift ;;
    \\      -d|--directory)
    \\        __shelly_directory_mode=1; __shelly_install_args+=("$1"); shift ;;
    \\      -T|--no-target-directory)
    \\        __shelly_no_target_directory=1; __shelly_install_args+=("$1"); shift ;;
    \\      -D|-p|--preserve-timestamps|-s|--strip|-v|--verbose|-C|--compare|-b|-Z|--backup|--backup=*|--mode=*|-m?*|-Dm?*)
    \\        __shelly_install_args+=("$1"); shift ;;
    \\      -*)
    \\        __shelly_ambiguous=1; __shelly_install_args+=("$1"); shift ;;
    \\      *)
    \\        __shelly_install_args+=("$1"); __shelly_operands+=("$1")
    \\        shift ;;
    \\    esac
    \\  done
    \\  if { [ "$__shelly_have_owner" -eq 1 ] || [ "$__shelly_have_group" -eq 1 ]; } && [ "$__shelly_ambiguous" -eq 1 ]; then
    \\    __shelly_metadata_reject; return $?
    \\  fi
    \\  /usr/bin/install "${__shelly_install_args[@]}" || return $?
    \\  if [ "$__shelly_have_owner" -eq 0 ] && [ "$__shelly_have_group" -eq 0 ]; then return 0; fi
    \\  __shelly_record_install_target() {
    \\    __shelly_target=$1
    \\    if [ "$__shelly_have_owner" -eq 1 ]; then
    \\      __shelly_value=$__shelly_owner
    \\      if [ "$__shelly_have_group" -eq 1 ]; then __shelly_value="${__shelly_value}:${__shelly_group}"; fi
    \\      __shelly_record_ownership C "$__shelly_value" "$__shelly_target" || return $?
    \\    elif [ "$__shelly_have_group" -eq 1 ]; then
    \\      __shelly_record_ownership G "$__shelly_group" "$__shelly_target" || return $?
    \\    fi
    \\  }
    \\  if [ "$__shelly_directory_mode" -eq 1 ]; then
    \\    for __shelly_target in "${__shelly_operands[@]}"; do __shelly_record_install_target "$__shelly_target" || return $?; done
    \\  elif [ -n "$__shelly_target_directory" ]; then
    \\    for __shelly_source in "${__shelly_operands[@]}"; do
    \\      __shelly_record_install_target "$__shelly_target_directory/$(/usr/bin/basename -- "$__shelly_source")" || return $?
    \\    done
    \\  else
    \\    [ "${#__shelly_operands[@]}" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\    __shelly_destination=${__shelly_operands[-1]}
    \\    if [ "$__shelly_no_target_directory" -eq 0 ] && { [ "${#__shelly_operands[@]}" -gt 2 ] || [ -d "$__shelly_destination" ]; }; then
    \\      for __shelly_source in "${__shelly_operands[@]:0:${#__shelly_operands[@]}-1}"; do
    \\        __shelly_record_install_target "$__shelly_destination/$(/usr/bin/basename -- "$__shelly_source")" || return $?
    \\      done
    \\    else
    \\      __shelly_record_install_target "$__shelly_destination" || return $?
    \\    fi
    \\  fi
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
