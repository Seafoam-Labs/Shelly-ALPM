//! Native Arch root provisioning used by Shelly's isolated build coordinator.
//!
//! The public coordinator re-executes Shelly in a private mount/PID namespace.
//! This module gives the selected backend explicit target-owned paths and performs the
//! repository transaction without depending on the `pacstrap` shell script.

const std = @import("std");
const paths = @import("paths");
const backend_selection = @import("backend.zig");
const diagnostics_module = @import("diagnostics");
const native_output = @import("native_output");
const manager_module = @import("manager.zig");
const events = @import("events.zig");
const operation_api = @import("operation_context");
const process_runner = @import("../aur/builder.zig");
pub const build_root = @import("build_root.zig");

pub const wrapper_argument = "__shellystrap";
pub const plan_mismatch_exit_code: u8 = 4;
pub const marker_name = ".shelly-bootstrap-root";

pub const Options = struct {
    backend: ?backend_selection.Backend = null,
    root_path: []const u8,
    config_path: []const u8 = paths.config_file,
    host_gpg_directory: []const u8 = paths.keyring,
    packages: []const []const u8,
    dependency_plan: ?[]const u8 = null,
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
        stderr.print("Could not provision the isolated build root because the bootstrap request is invalid. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics_module.cause(err), @errorName(err) }) catch {};
        return 2;
    };
    _ = bootstrapReporting(allocator, io, environ, options, stderr) catch |err| {
        stderr.print("Could not provision the isolated build root. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics_module.cause(err), @errorName(err) }) catch {};
        return if (err == error.DependencyPlanMismatch) plan_mismatch_exit_code else 1;
    };
    return 0;
}

pub fn parseArguments(arguments: []const []const u8) !Options {
    var root_path: ?[]const u8 = null;
    var backend: ?backend_selection.Backend = null;
    var config_path: []const u8 = paths.config_file;
    var gpg_directory: []const u8 = paths.keyring;
    var dependency_plan: ?[]const u8 = null;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--")) {
            const packages = arguments[index + 1 ..];
            if (root_path == null or packages.len == 0) return error.InvalidBootstrapArguments;
            return .{
                .root_path = root_path.?,
                .backend = backend,
                .config_path = config_path,
                .host_gpg_directory = gpg_directory,
                .packages = packages,
                .dependency_plan = dependency_plan,
            };
        }
        if (std.mem.eql(u8, argument, "--root")) {
            index += 1;
            if (index >= arguments.len or root_path != null) return error.InvalidBootstrapArguments;
            root_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--backend")) {
            index += 1;
            if (index >= arguments.len) return error.InvalidBootstrapArguments;
            backend = try backend_selection.Backend.parse(arguments[index]);
            try backend.?.validate();
        } else if (std.mem.eql(u8, argument, "--config")) {
            index += 1;
            if (index >= arguments.len) return error.InvalidBootstrapArguments;
            config_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--dependency-plan")) {
            index += 1;
            if (index >= arguments.len or dependency_plan != null) return error.InvalidBootstrapArguments;
            dependency_plan = arguments[index];
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
    io: ?std.Io = null,
    last_progress: ?std.Io.Timestamp = null,
    last_progress_stage: ?u64 = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    mutex: std.Io.Mutex = .init,
    observe_downloads: bool = false,
    downloads: std.StringHashMapUnmanaged(Transfer) = .empty,
    last_download_progress: ?std.Io.Timestamp = null,

    const Transfer = struct {
        operation_id: ?operation_api.OperationId = null,
        bytes: u64 = 0,
        total: ?u64 = null,
        active: bool = true,
        transferred: bool = false,
        unchanged: bool = false,
    };

    fn deinit(self: *DiagnosticOutput) void {
        self.clearDownloads();
        self.downloads.deinit(self.allocator);
    }

    fn clearDownloads(self: *DiagnosticOutput) void {
        var keys = self.downloads.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.downloads.clearRetainingCapacity();
        self.last_download_progress = null;
    }

    fn lock(self: *DiagnosticOutput) void {
        if (self.io) |io| self.mutex.lockUncancelable(io);
    }

    fn unlock(self: *DiagnosticOutput) void {
        if (self.io) |io| self.mutex.unlock(io);
    }

    fn handleDownload(data: ?*anyopaque, update: events.DownloadUpdate) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        self.writeDownload(update);
    }

    fn writeDownload(self: *DiagnosticOutput, update: events.DownloadUpdate) void {
        if (update.state == .batch_start) {
            self.clearDownloads();
            return;
        }
        const entry = self.downloads.getOrPut(self.allocator, update.name) catch return;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, update.name) catch {
                _ = self.downloads.remove(update.name);
                return;
            };
            entry.value_ptr.* = .{ .operation_id = update.operation_id };
        }
        const transfer = entry.value_ptr;
        if (update.state != .started and update.operation_id != null and update.operation_id != transfer.operation_id) return;
        switch (update.state) {
            .batch_start => unreachable,
            .started => transfer.* = .{ .operation_id = update.operation_id },
            .retry => {
                if (!update.resuming) transfer.* = .{ .operation_id = transfer.operation_id };
            },
            .progress => {
                transfer.bytes = update.bytes;
                transfer.total = update.total;
            },
            .completed, .unchanged, .failed => {
                transfer.active = false;
                transfer.transferred = update.state != .failed;
                transfer.bytes = update.bytes;
                transfer.total = update.total;
            },
        }
        defer self.stderr.flush() catch {};
        if (update.state != .progress) {
            const label: []const u8 = switch (update.state) {
                .started => "Retrieving package",
                .retry => "Retrying download",
                .completed => "Package retrieval completed",
                .unchanged => "Download skipped",
                .failed => "Download failed",
                .batch_start, .progress => unreachable,
            };
            self.stderr.print("shellystrap: {s}: {s}\n", .{ label, update.name }) catch {};
        }
        if (update.state == .started or update.state == .retry) return;
        var active: usize = 0;
        var transferred: usize = 0;
        var bytes: u64 = 0;
        var total: u64 = 0;
        var known = true;
        var values = self.downloads.valueIterator();
        while (values.next()) |value| {
            active += @intFromBool(value.active);
            transferred += @intFromBool(value.transferred);
            bytes +|= value.bytes;
            if (value.total) |size| total +|= size else known = false;
        }
        if (self.io) |io| {
            const now = std.Io.Clock.awake.now(io);
            if (self.last_download_progress) |last| {
                if (active != 0 and last.durationTo(now).toMilliseconds() < 250) return;
            }
            self.last_download_progress = now;
        }
        self.stderr.print("shellystrap: Downloads: {d} active, {d} transferred ({d}", .{ active, transferred, bytes }) catch {};
        if (known) self.stderr.print("/{d}", .{total}) catch {};
        self.stderr.writeAll(" bytes)\n") catch {};
    }

    fn handleOperation(data: ?*anyopaque, event: operation_api.Event) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        switch (event) {
            .started => |started| {
                if (started.envelope.backend == .download) {
                    self.writeDownload(.{ .name = std.fs.path.basename(started.envelope.subject orelse "download"), .operation_id = started.envelope.operation_id, .state = .started });
                } else if (started.envelope.parent_id == null) self.clearDownloads();
            },
            .status => |status| {
                if (status.envelope.backend == .download) {
                    const name = std.fs.path.basename(status.envelope.subject orelse "download");
                    const code = status.code orelse "";
                    if (std.mem.eql(u8, code, "download.retry") or std.mem.eql(u8, code, "download.resume")) self.writeDownload(.{ .name = name, .operation_id = status.envelope.operation_id, .state = .retry, .resuming = std.mem.eql(u8, code, "download.resume") });
                    if (std.mem.eql(u8, code, "download.skipped")) {
                        if (self.downloads.getPtr(name)) |transfer| transfer.unchanged = true;
                    }
                } else self.writeStatus(status);
            },
            .progress => |progress| {
                if (progress.envelope.backend == .download) {
                    self.writeDownload(.{ .name = std.fs.path.basename(progress.envelope.subject orelse progress.update.message orelse "download"), .operation_id = progress.envelope.operation_id, .state = .progress, .bytes = progress.update.bytes_completed orelse 0, .total = progress.update.bytes_total });
                } else self.writeProgress(progress.update);
            },
            .completed => |completed| if (completed.envelope.backend == .download) {
                const name = std.fs.path.basename(completed.envelope.subject orelse "download");
                const transfer = self.downloads.get(name) orelse Transfer{};
                self.writeDownload(.{ .name = name, .operation_id = completed.envelope.operation_id, .state = if (completed.status != .success) .failed else if (transfer.unchanged) .unchanged else .completed, .bytes = transfer.bytes, .total = transfer.total });
            },
            else => {},
        }
    }

    fn writeStatus(self: *DiagnosticOutput, status: anytype) void {
        if (status.level == .debug) return;
        // Hooks and scriptlets also reach the dedicated legacy handlers.
        if (status.code) |code| if (std.mem.eql(u8, code, "alpm.scriptlet")) return;
        if (status.native_code == @intFromEnum(native_output.EventType.hook_run_start)) return;
        defer self.stderr.flush() catch {};
        if (status.package_name) |name| {
            self.stderr.print("shellystrap: {s}: {s}\n", .{ name, status.message }) catch {};
        } else self.stderr.print("shellystrap: {s}\n", .{status.message}) catch {};
    }

    fn writeProgress(self: *DiagnosticOutput, update: operation_api.ProgressUpdate) void {
        const stage = @import("native_output").progressLabel(update.native_code) orelse update.stage orelse "Transaction";
        if (std.mem.eql(u8, stage, "hook")) return;
        const key = std.hash.Wyhash.hash(0, stage);
        // Byte callbacks can be very frequent. Preserve stage changes
        // and completion while limiting intermediate output to 4 Hz.
        if (self.io) |io| {
            const now = std.Io.Clock.awake.now(io);
            const complete = if (update.percentage) |percent|
                percent >= 100
            else if (update.bytes_total) |total|
                total != 0 and (update.bytes_completed orelse 0) >= total
            else
                false;
            if (self.last_progress) |last| {
                if (self.last_progress_stage == key and !complete and last.durationTo(now).toMilliseconds() < 250) return;
            }
            self.last_progress = now;
        }
        self.last_progress_stage = key;
        defer self.stderr.flush() catch {};
        self.stderr.print("shellystrap: {s}", .{stage}) catch {};
        if (update.message) |message| self.stderr.print(": {s}", .{message}) catch {};
        if (update.percentage) |percent| self.stderr.print(" {d:.0}%", .{percent}) catch {};
        if (update.bytes_completed) |bytes| {
            self.stderr.print(" ({d}", .{bytes}) catch {};
            if (update.bytes_total) |total| self.stderr.print("/{d}", .{total}) catch {};
            self.stderr.writeAll(" bytes)") catch {};
        } else if (update.completed) |completed| {
            self.stderr.print(" ({d}", .{completed}) catch {};
            if (update.total) |total| self.stderr.print("/{d}", .{total}) catch {};
            self.stderr.writeAll(")") catch {};
        }
        self.stderr.writeByte('\n') catch {};
    }

    fn handleInformational(data: ?*anyopaque, args: events.InformationalArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        if (self.observe_downloads and (args.event_type == .pkg_retrieve_start or args.event_type == .pkg_retrieve_done)) return;
        self.writeStatus(.{ .level = operation_api.StatusLevel.information, .message = args.message, .package_name = args.package_name, .code = args.code, .native_code = @as(?i64, @intFromEnum(args.event_type)) });
    }

    fn handleProgress(data: ?*anyopaque, args: events.ProgressArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        if (self.observe_downloads and (args.progress_type == 100 or args.progress_type == 101)) return;
        self.writeProgress(.{ .stage = "transaction", .message = args.pkg_name, .percentage = @floatFromInt(std.math.clamp(args.percent, 0, 100)), .completed = args.current, .total = args.howmany, .native_code = args.progress_type });
    }

    fn handleError(data: ?*anyopaque, args: events.ErrorArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        defer self.stderr.flush() catch {};
        const message = std.mem.trimEnd(u8, args.message, "\r\n");
        // Detailed transaction failures already contain punctuation and technical
        // codes. Preserve those lines without appending a dot to the error code.
        const suffix = if (std.mem.indexOfScalar(u8, message, '\n') != null or std.mem.endsWith(u8, message, ".")) "" else ".";
        self.stderr.print("Could not provision the isolated build root: {f}{s}\n", .{ diagnostics_module.safe(message), suffix }) catch {};
    }

    fn handleScriptlet(data: ?*anyopaque, args: events.ScriptletArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        defer self.stderr.flush() catch {};
        self.stderr.print("shellystrap: scriptlet: {s}\n", .{
            std.mem.trimEnd(u8, args.line, "\r\n"),
        }) catch {};
    }

    fn handleHook(data: ?*anyopaque, args: events.HookArgs) void {
        const self: *DiagnosticOutput = @ptrCast(@alignCast(data.?));
        self.lock();
        defer self.unlock();
        defer self.stderr.flush() catch {};
        self.stderr.print("shellystrap: hook: {s}: {s}\n", .{
            args.name orelse "unknown",
            args.description orelse "Running package initialization",
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
        writer.flush() catch {};
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
    destination.flush() catch {};
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
            const detail = std.fmt.bufPrint(&detail_buffer, "Could not start the setup command while preparing the isolated build root. {0s}\n\nTechnical details: {1s}", .{ diagnostics_module.cause(err), @errorName(err) }) catch
                "Could not start the setup command while preparing the isolated build root.";
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

    const database_path = try rootJoin(allocator, options.root_path, paths.database[1..]);
    defer allocator.free(database_path);
    const cache_path = try rootJoin(allocator, options.root_path, paths.cache[1..]);
    defer allocator.free(cache_path);
    const log_path = try rootJoin(allocator, options.root_path, paths.bootstrap_log[1..]);
    defer allocator.free(log_path);
    const target_gpg_path = try rootJoin(allocator, options.root_path, paths.keyring[1..]);
    defer allocator.free(target_gpg_path);

    try prepareFilesystem(allocator, io, options, database_path, cache_path, target_gpg_path);

    var mounts = MountScope.init(allocator, io, options.root_path);
    defer mounts.deinit();
    try mounts.setup();

    var configuration_digest: [64]u8 = undefined;
    const manager = try manager_module.Manager.init(allocator, environ, .{
        .backend = options.backend,
        .config_path = options.config_path,
        .configuration_digest = &configuration_digest,
        .use_root = true,
        .root_directory = options.root_path,
        .database_path = database_path,
        .cache_directory = cache_path,
        .log_file = log_path,
        .gpg_directory = target_gpg_path,
        .root_hooks_only = true,
    });
    defer manager.deinit();

    // Both backends rescan target hook directories after installation. This
    // initializes newly installed tools (including TeX) without host hooks.

    var diagnostic_output: DiagnosticOutput = undefined;
    defer if (diagnostic_writer != null) diagnostic_output.deinit();
    if (diagnostic_writer) |writer| {
        diagnostic_output = .{ .stderr = writer, .io = io, .allocator = allocator, .observe_downloads = true };
        if (manager.backend() == .rlpm) {
            _ = try manager.dispatcher.addOperationHandler(.{ .function = DiagnosticOutput.handleOperation, .data = &diagnostic_output });
        } else {
            _ = try manager.dispatcher.addDownloadHandler(.{ .function = DiagnosticOutput.handleDownload, .data = &diagnostic_output });
            _ = try manager.dispatcher.addInformationalHandler(.{ .function = DiagnosticOutput.handleInformational, .data = &diagnostic_output });
            _ = try manager.dispatcher.addProgressHandler(.{ .function = DiagnosticOutput.handleProgress, .data = &diagnostic_output });
        }
        _ = try manager.dispatcher.addErrorHandler(.{
            .function = DiagnosticOutput.handleError,
            .data = &diagnostic_output,
        });
        _ = try manager.dispatcher.addScriptletHandler(.{
            .function = DiagnosticOutput.handleScriptlet,
            .data = &diagnostic_output,
        });
        _ = try manager.dispatcher.addHookHandler(.{
            .function = DiagnosticOutput.handleHook,
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
    if (options.dependency_plan) |path| {
        const plans = manager_module.Manager.build_plan;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(plans.Plan, allocator, bytes, .{});
        defer parsed.deinit();
        try parsed.value.validate(allocator);
        if (!std.mem.eql(u8, parsed.value.backend, @tagName(manager.backend()))) return error.DependencyPlanMismatch;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (!std.mem.eql(u8, &configuration_digest, parsed.value.configurationDigest)) return error.DependencyPlanMismatch;
        const targets = try a.alloc([:0]const u8, parsed.value.packages.len);
        for (parsed.value.packages, targets) |package, *target|
            target.* = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ package.repository, package.name }, 0);
        try manager.install_build_packages(targets, parsed.value.packages);
    } else try manager.install_packages(package_names, .{ .needed = true });
    if (manager.packageSetupFailed()) return error.BootstrapPackageSetupFailed;

    const installed = try manager.get_installed_packages();
    defer {
        for (installed) |*package| package.deinit(allocator);
        allocator.free(installed);
    }
    if (installed.len == 0) return error.EmptyBootstrapRoot;
    try requireFile(io, allocator, options.root_path, "usr/bin/bash");
    try requireDirectory(io, allocator, options.root_path, paths.database[1..] ++ "/local");
    try finalizeRoot(allocator, io, environ, options.root_path, diagnostic_writer);
    try requireFile(io, allocator, options.root_path, "etc/ld.so.cache");
    try requireFile(io, allocator, options.root_path, "etc/passwd");
    try requireDirectory(io, allocator, options.root_path, "var/tmp");
    try requireFile(io, allocator, options.root_path, "etc/ssl/certs/ca-certificates.crt");
    if (comptime build_root.rlpm_only) {
        var root = try std.Io.Dir.cwd().openDir(io, options.root_path, .{});
        defer root.close(io);
        try prepareGuestQueries(io, root);
    }
    return .{ .installed_package_count = installed.len };
}

fn prepareGuestQueries(io: std.Io, root: std.Io.Dir) !void {
    // Dependencies are provisioned by the coordinator. Guest metadata queries
    // need only the local database, not host repository Include paths.
    try root.writeFile(io, .{
        .sub_path = paths.config_file[1..],
        .data = "[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\n",
    });
    // Without the pacman package these paths retain the provisioning umask.
    // The unprivileged builder needs them to query installed package metadata.
    for ([_][]const u8{ paths.database[1..], paths.database[1..] ++ "/local" }) |path|
        try root.setFilePermissions(io, path, .fromMode(0o755), .{});
    for ([_][]const u8{ paths.config_file[1..], paths.database[1..] ++ "/local/ALPM_DB_VERSION" }) |path|
        try root.setFilePermissions(io, path, .fromMode(0o644), .{});
}

test "bootstrap guest package queries can read configuration and database under restrictive permissions" {
    const t = std.testing;
    var fixture = t.tmpDir(.{});
    defer fixture.cleanup();
    try fixture.dir.createDirPath(t.io, "etc");
    try fixture.dir.createDirPath(t.io, paths.database[1..] ++ "/local");
    for ([_][]const u8{ paths.database[1..], paths.database[1..] ++ "/local" }) |path|
        try fixture.dir.setFilePermissions(t.io, path, .fromMode(0o700), .{});
    try fixture.dir.writeFile(t.io, .{ .sub_path = paths.config_file[1..], .data = "[host]\nInclude = /host-only/mirrorlist\n" });
    try fixture.dir.writeFile(t.io, .{ .sub_path = paths.database[1..] ++ "/local/ALPM_DB_VERSION", .data = "9\n" });
    for ([_][]const u8{ paths.config_file[1..], paths.database[1..] ++ "/local/ALPM_DB_VERSION" }) |path|
        try fixture.dir.setFilePermissions(t.io, path, .fromMode(0o600), .{});
    try prepareGuestQueries(t.io, fixture.dir);
    for ([_][]const u8{ paths.database[1..], paths.database[1..] ++ "/local" }) |path|
        try t.expectEqual(@as(u32, 0o755), (try fixture.dir.statFile(t.io, path, .{})).permissions.toMode() & 0o7777);
    for ([_][]const u8{ paths.config_file[1..], paths.database[1..] ++ "/local/ALPM_DB_VERSION" }) |path|
        try t.expectEqual(@as(u32, 0o644), (try fixture.dir.statFile(t.io, path, .{})).permissions.toMode() & 0o7777);
    const config = try fixture.dir.readFileAlloc(t.io, paths.config_file[1..], t.allocator, .limited(4096));
    defer t.allocator.free(config);
    try t.expect(std.mem.indexOf(u8, config, "Include") == null);
    try t.expect(std.mem.indexOf(u8, config, "SigLevel = Required") != null);
    const version = try fixture.dir.readFileAlloc(t.io, paths.database[1..] ++ "/local/ALPM_DB_VERSION", t.allocator, .limited(32));
    defer t.allocator.free(version);
    try t.expectEqualStrings("9\n", version);
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
        paths.config_directory[1..], paths.database[1..], paths.cache[1..], "var/log",
        "proc",                      "sys",               "dev",            "run",
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

    const target_config = try rootJoin(allocator, options.root_path, paths.config_file[1..]);
    defer allocator.free(target_config);
    try std.Io.Dir.copyFile(.cwd(), options.config_path, .cwd(), target_config, io, .{});

    const host_mirrorlist = paths.mirrorlist;
    if (std.Io.Dir.cwd().statFile(io, host_mirrorlist, .{})) |_| {
        const target_mirrorlist = try rootJoin(allocator, options.root_path, paths.mirrorlist[1..]);
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

test "internal bootstrap diagnostics write native backend failures only to stderr" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var diagnostics: DiagnosticOutput = .{ .stderr = &output.writer };

    DiagnosticOutput.handleError(&diagnostics, .{
        .message = "invalid or corrupted package (PGP signature)\n",
    });
    DiagnosticOutput.handleScriptlet(&diagnostics, .{
        .line = "a package scriptlet failed\n",
    });
    DiagnosticOutput.handleHook(&diagnostics, .{
        .name = "72-texlive-fmtutil.hook",
        .description = "Updating TeXLive format files...",
        .position = 1,
        .total = 1,
    });

    try std.testing.expectEqualStrings(
        "Could not provision the isolated build root: invalid or corrupted package (PGP signature).\n" ++
            "shellystrap: scriptlet: a package scriptlet failed\n" ++
            "shellystrap: hook: 72-texlive-fmtutil.hook: Updating TeXLive format files...\n",
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

test "bootstrap streams short diagnostics and progress before provisioning finishes" {
    const t = std.testing;
    var fixture = t.tmpDir(.{});
    defer fixture.cleanup();
    var file = try fixture.dir.createFile(t.io, "output", .{});
    defer file.close(t.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(t.io, &buffer);
    var output: DiagnosticOutput = .{ .stderr = &writer.interface };
    var context = operation_api.OperationContext.init(t.allocator, t.io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    var previous_size: u64 = 0;
    for (0..6) |step| {
        switch (step) {
            0 => DiagnosticOutput.handleScriptlet(&output, .{ .line = "initializing package" }),
            1 => DiagnosticOutput.handleHook(&output, .{ .name = "fixture.hook", .description = "Updating cache", .position = 1, .total = 1 }),
            2 => DiagnosticOutput.handleError(&output, .{ .message = "fixture failure" }),
            3 => DiagnosticOutput.handleOperation(&output, .{ .status = .{ .envelope = operation.envelope, .level = .information, .message = "Checking package databases" } }),
            4 => DiagnosticOutput.handleOperation(&output, .{ .progress = .{ .envelope = operation.envelope, .update = .{ .stage = "download", .message = "fixture.pkg.tar", .bytes_completed = 4, .bytes_total = 8 } } }),
            5 => {
                var finalizer: FinalizerOutput = .{ .writer = &writer.interface, .name = "ldconfig" };
                FinalizerOutput.handle(&finalizer, .stdout, "updated");
            },
            else => unreachable,
        }
        const size = (try file.stat(t.io)).size;
        try t.expect(size > previous_size);
        try t.expect(size < buffer.len);
        previous_size = size;
    }
    // Operation mirrors of legacy hook/scriptlet output must not print twice.
    DiagnosticOutput.handleOperation(&output, .{ .status = .{ .envelope = operation.envelope, .level = .information, .message = "duplicate", .code = "alpm.scriptlet" } });
    DiagnosticOutput.handleOperation(&output, .{ .status = .{ .envelope = operation.envelope, .level = .information, .message = "duplicate", .native_code = 36 } });
    try t.expectEqual(previous_size, (try file.stat(t.io)).size);
    output.io = t.io;
    // Force an active throttle window without timing-sensitive sleeps.
    output.last_progress = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(60));
    DiagnosticOutput.handleOperation(&output, .{ .progress = .{ .envelope = operation.envelope, .update = .{ .stage = "download", .message = "fixture.pkg.tar", .bytes_completed = 5, .bytes_total = 8 } } });
    try t.expectEqual(previous_size, (try file.stat(t.io)).size);
    DiagnosticOutput.handleOperation(&output, .{ .progress = .{ .envelope = operation.envelope, .update = .{ .stage = "download", .message = "fixture.pkg.tar", .bytes_completed = 8, .bytes_total = 8 } } });
    try t.expect((try file.stat(t.io)).size > previous_size);
    const contents = try fixture.dir.readFileAlloc(t.io, "output", t.allocator, .limited(4096));
    defer t.allocator.free(contents);
    try t.expect(std.mem.indexOf(u8, contents, "fixture.pkg.tar (4/8 bytes)") != null);
}

test "bootstrap native operation and legacy callbacks use identical readable formatting" {
    const t = std.testing;
    var legacy: std.Io.Writer.Allocating = .init(t.allocator);
    defer legacy.deinit();
    var shared: std.Io.Writer.Allocating = .init(t.allocator);
    defer shared.deinit();
    var legacy_output: DiagnosticOutput = .{ .stderr = &legacy.writer };
    var shared_output: DiagnosticOutput = .{ .stderr = &shared.writer };
    var context = operation_api.OperationContext.init(t.allocator, t.io);
    defer context.deinit();
    _ = try context.subscribe(.{ .function = DiagnosticOutput.handleOperation, .data = &shared_output });
    var operation = context.begin(.{ .backend = .alpm, .kind = .install });
    defer operation.finish(.success);
    var dispatcher = events.Dispatcher.init(t.allocator);
    defer dispatcher.deinit();
    dispatcher.setOperation(&operation);
    _ = try dispatcher.addInformationalHandler(.{ .function = DiagnosticOutput.handleInformational, .data = &legacy_output });
    _ = try dispatcher.addProgressHandler(.{ .function = DiagnosticOutput.handleProgress, .data = &legacy_output });
    for ([_]*DiagnosticOutput{ &legacy_output, &shared_output }) |output| {
        _ = try dispatcher.addHookHandler(.{ .function = DiagnosticOutput.handleHook, .data = output });
        _ = try dispatcher.addScriptletHandler(.{ .function = DiagnosticOutput.handleScriptlet, .data = output });
    }
    dispatcher.raiseInformational(.{ .event_type = .package_operation_start, .message = "Installing package: demo-1-1" });
    dispatcher.raiseProgress(.{ .progress_type = 0, .pkg_name = "demo", .percent = 100, .current = 1, .howmany = 2 });
    dispatcher.raiseInformational(.{ .event_type = .package_operation_done, .message = "Package operation completed.", .package_name = "demo", .code = "alpm.package_installed" });
    dispatcher.raiseScriptlet(.{ .line = "setup output\n" });
    dispatcher.raiseHook(.{ .name = "demo.hook", .description = "(1/1) Updating cache", .position = 1, .total = 1 });
    dispatcher.raiseInformational(.{ .event_type = .hook_run_start, .message = "(1/1) Updating cache" });
    try t.expectEqualStrings(legacy.written(), shared.written());
    try t.expectEqualStrings(
        "shellystrap: Installing package: demo-1-1\n" ++
            "shellystrap: Installing: demo 100% (1/2)\n" ++
            "shellystrap: demo: Package operation completed.\n" ++
            "shellystrap: scriptlet: setup output\n" ++
            "shellystrap: hook: demo.hook: (1/1) Updating cache\n",
        shared.written(),
    );
}

test "bootstrap aggregates interleaved transfers and flushes terminal output for both callback paths" {
    const t = std.testing;
    var legacy: std.Io.Writer.Allocating = .init(t.allocator);
    defer legacy.deinit();
    var shared: std.Io.Writer.Allocating = .init(t.allocator);
    defer shared.deinit();
    var legacy_output: DiagnosticOutput = .{ .stderr = &legacy.writer, .io = t.io, .allocator = t.allocator };
    defer legacy_output.deinit();
    var shared_output: DiagnosticOutput = .{ .stderr = &shared.writer, .io = t.io, .allocator = t.allocator };
    defer shared_output.deinit();
    const names = [_][]const u8{ "first.pkg", "second.pkg", "third.pkg" };
    var envelopes: [3]operation_api.Envelope = undefined;
    for (&envelopes, names, 0..) |*envelope, name, index| {
        envelope.* = .{ .operation_id = index + 1, .parent_id = 10, .backend = .download, .kind = .download, .subject = name };
        DiagnosticOutput.handleDownload(&legacy_output, .{ .name = name, .state = .started });
        DiagnosticOutput.handleOperation(&shared_output, .{ .started = .{ .envelope = envelope.* } });
    }
    for (envelopes, names) |envelope, name| {
        DiagnosticOutput.handleDownload(&legacy_output, .{ .name = name, .state = .progress, .bytes = 5, .total = 10 });
        DiagnosticOutput.handleOperation(&shared_output, .{ .progress = .{ .envelope = envelope, .update = .{ .stage = "download", .bytes_completed = 5, .bytes_total = 10 } } });
        // Keep the subsequent callbacks inside the throttle without a sleep.
        for ([_]*DiagnosticOutput{ &legacy_output, &shared_output }) |output| output.last_download_progress = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(60));
    }
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, legacy.written(), "Downloads:"));
    try t.expect(std.mem.indexOf(u8, legacy.written(), "3 active, 0 transferred") != null);
    // One transfer with unknown length keeps the batch byte count honest.
    for ([_]*DiagnosticOutput{ &legacy_output, &shared_output }) |output| output.last_download_progress = null;
    DiagnosticOutput.handleDownload(&legacy_output, .{ .name = names[2], .state = .progress, .bytes = 7 });
    DiagnosticOutput.handleOperation(&shared_output, .{ .progress = .{ .envelope = envelopes[2], .update = .{ .stage = "download", .bytes_completed = 7 } } });
    try t.expect(std.mem.indexOf(u8, legacy.written(), "3 active, 0 transferred (17 bytes)") != null);
    for ([_]*DiagnosticOutput{ &legacy_output, &shared_output }) |output| output.last_download_progress = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(60));
    const before = legacy.written().len;
    DiagnosticOutput.handleDownload(&legacy_output, .{ .name = names[0], .state = .completed, .bytes = 5, .total = 10 });
    DiagnosticOutput.handleOperation(&shared_output, .{ .completed = .{ .envelope = envelopes[0], .status = .success } });
    try t.expect(legacy.written().len > before);
    // A new mirror attempt starts from zero; a prior completed transfer must
    // not leave a transferred count or 100% bar for its replacement.
    const old_attempt = envelopes[0];
    envelopes[0].operation_id = 4;
    DiagnosticOutput.handleDownload(&legacy_output, .{ .name = names[0], .state = .started });
    DiagnosticOutput.handleOperation(&shared_output, .{ .started = .{ .envelope = envelopes[0] } });
    DiagnosticOutput.handleOperation(&shared_output, .{ .progress = .{ .envelope = old_attempt, .update = .{ .stage = "download", .bytes_completed = 10, .bytes_total = 10 } } });
    try t.expect(!shared_output.downloads.get(names[0]).?.transferred);
    try t.expectEqual(@as(u64, 0), shared_output.downloads.get(names[0]).?.bytes);
    DiagnosticOutput.handleDownload(&legacy_output, .{ .name = names[1], .state = .retry });
    DiagnosticOutput.handleOperation(&shared_output, .{ .status = .{ .envelope = envelopes[1], .level = .information, .message = "Retrying download: second.pkg", .code = "download.retry" } });
    try t.expectEqualStrings(legacy.written(), shared.written());
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, shared.written(), "Package retrieval completed: first.pkg"));
    try t.expect(std.mem.indexOf(u8, shared.written(), "Retrying download: second.pkg") != null);
}

test "bootstrap preserves multiline dependency failures and technical details" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var diagnostics: DiagnosticOutput = .{ .stderr = &output.writer };
    const message = "\"first\" requires \"missing-lib>=2.0\", which could not be satisfied.\n" ++
        "\"second\" requires \"other-lib=3\", which could not be satisfied.\n\n" ++
        "Technical details: UnsatisfiedDependencies";
    DiagnosticOutput.handleError(&diagnostics, .{ .message = message });
    try std.testing.expectEqualStrings("Could not provision the isolated build root: " ++ message ++ "\n", output.written());
}
