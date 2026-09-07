const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const format = @import("../output/format.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const list_updates = @import("list_updates.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const xdg = @import("../runtime/xdg.zig");
const spec = @import("../cli/spec.zig");
const aur_url = @import("../config/aur_url.zig");

const standard_command_path = "shelly install standard";
const appimage_command_path = "shelly install appimage";
const aur_command_path = "shelly install aur";
const flatpak_command_path = "shelly install flatpak";

const InstallError = error{
    BackendFailed,
    DownloadFailed,
    NoFlatpakRemote,
    UnsupportedLocalPackage,
};

const Real = struct {
    pub fn run(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        if (std.mem.eql(u8, invocation.command.path, standard_command_path))
            return runStandard(context, operation_context, invocation);
        if (std.mem.eql(u8, invocation.command.path, aur_command_path))
            return runAur(context, operation_context, invocation);
        if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
            return runAppImage(context, operation_context, invocation);
        if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) {
            if (isFlatpakRepair(invocation))
                return runFlatpakRepair(context, operation_context, invocation);
            if (flatpakFileKind(invocation)) |kind|
                return runFlatpakFile(context, operation_context, invocation, kind);
            return runFlatpak(context, operation_context, invocation);
        }
        unreachable;
    }
};

pub const Backend = enum {
    standard,
    aur,
    appimage,
    flatpak,
};

pub const CallOptions = struct {
    no_confirm: bool = false,
    ui_mode: bool = false,
    aur_url: ?[]const u8 = null,
};

pub const Caller = struct {
    context: *runtime.RuntimeContext,
    manifest: spec.Manifest,

    pub fn init(context: *runtime.RuntimeContext) !Caller {
        return .{
            .context = context,
            .manifest = try spec.Manifest.load(context.allocator),
        };
    }

    pub fn call(
        self: *Caller,
        backend: Backend,
        targets: []const []const u8,
        options: CallOptions,
    ) !u8 {
        const arguments = try callArguments(self.context.allocator, backend, targets, options);
        defer self.context.allocator.free(arguments);

        var outcome = try parser.parse(self.context.allocator, &self.manifest, arguments);
        if (outcome != .dispatch) return error.InvalidInstallInvocation;
        return (try dispatch(self.context, &outcome.dispatch)) orelse error.InvalidInstallInvocation;
    }
};

/// Runs the regular install command path for an internal caller. This keeps
/// validation, elevation, output, question defaults, and backend resolution
/// identical to a user-entered `shelly install <backend> ...` invocation.
pub fn call(
    context: *runtime.RuntimeContext,
    backend: Backend,
    targets: []const []const u8,
    options: CallOptions,
) !u8 {
    var caller = try Caller.init(context);
    return caller.call(backend, targets, options);
}

fn callArguments(
    allocator: std.mem.Allocator,
    backend: Backend,
    targets: []const []const u8,
    options: CallOptions,
) ![]const []const u8 {
    var arguments: std.ArrayList([]const u8) = .empty;
    errdefer arguments.deinit(allocator);

    try arguments.append(allocator, "install");
    try arguments.append(allocator, @tagName(backend));
    if (options.no_confirm) try arguments.append(allocator, "--no-confirm");
    if (options.ui_mode) try arguments.append(allocator, "--ui-mode");
    if (options.aur_url) |url| {
        try arguments.append(allocator, "--aur-url");
        try arguments.append(allocator, url);
    }
    try arguments.appendSlice(allocator, targets);
    return arguments.toOwnedSlice(allocator);
}

test "internal install calls preserve targets and automatic-answer globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arguments = try callArguments(
        allocator,
        .standard,
        &.{ "base", "linux" },
        .{ .no_confirm = true, .ui_mode = true, .aur_url = "https://atoll.seafoam-labs.org" },
    );
    const manifest = try spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, arguments);

    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings(standard_command_path, outcome.dispatch.command.path);
    try std.testing.expect(outcome.dispatch.globals.no_confirm);
    try std.testing.expect(outcome.dispatch.globals.ui_mode);
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org", aur_url.overrideValue(&outcome.dispatch).?);
    try std.testing.expectEqual(@as(usize, 2), outcome.dispatch.positionals.len);
    try std.testing.expectEqualStrings("base", outcome.dispatch.positionals[0]);
    try std.testing.expectEqualStrings("linux", outcome.dispatch.positionals[1]);
}

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isInstallPath(invocation.command.path)) return null;

    if (isAurVersionInstall(invocation)) {
        if (invocation.positionals.len == 0)
            return try reportValidationFailure(context, invocation, "No package specified.");
        if (invocation.positionals.len == 1)
            return try reportValidationFailure(context, invocation, "No commit specified.");
        if (invocation.positionals.len > 2)
            return try reportValidationFailure(
                context,
                invocation,
                "Install version accepts exactly one AUR package and one Git commit.",
            );
        if (optionEnabled(invocation, "--build-deps") or optionEnabled(invocation, "--make-deps"))
            return try reportValidationFailure(
                context,
                invocation,
                "Cannot combine --version with dependency-only installation options.",
            );
    }
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) {
        const ref_file = optionEnabled(invocation, "--ref-file");
        const bundle = optionEnabled(invocation, "--bundle");
        const repair = optionEnabled(invocation, "--repair");
        if (ref_file and bundle)
            return try reportValidationFailure(
                context,
                invocation,
                "Choose exactly one of --ref-file or --bundle.",
            );
        if ((ref_file or bundle) and
            (optionValue(invocation, "--remote") != null or
                optionValue(invocation, "--branch") != null or
                optionEnabled(invocation, "--runtime")))
            return try reportValidationFailure(
                context,
                invocation,
                "Cannot combine --ref-file or --bundle with --remote, --branch, or --runtime.",
            );
        if (repair and
            (ref_file or bundle or
                optionEnabled(invocation, "--user") or
                optionValue(invocation, "--remote") != null or
                optionValue(invocation, "--branch") != null or
                optionEnabled(invocation, "--runtime")))
            return try reportValidationFailure(
                context,
                invocation,
                "Cannot combine --repair with --user, --remote, --branch, --runtime, --ref-file, or --bundle.",
            );
    }
    if (needsPackages(invocation) and invocation.positionals.len == 0)
        return try reportValidationFailure(
            context,
            invocation,
            if (std.mem.eql(u8, invocation.command.path, standard_command_path))
                "Error: No packages specified"
            else
                "No packages specified.",
        );
    if (optionEnabled(invocation, "--build-deps") and dependencyTargetCount(invocation) > 1)
        return try reportValidationFailure(
            context,
            invocation,
            "Cannot build dependencies for multiple packages at once.",
        );

    if (isFlatpakRepair(invocation) and !invocation.globals.ui_mode and !elevation.isRoot()) {
        const elevate = repairTargetRequiresElevation(context, invocation.positionals[0]) catch |err| {
            if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
                try context.stderr.print("{s}\n", .{message});
                return 1;
            }
            try context.stderr.print("Unable to inspect Flatpak before repair: {t}\n", .{err});
            return 1;
        };
        if (elevate) {
            const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
                try context.stderr.print("Unable to elevate Flatpak repair: {t}\n", .{err});
                return 1;
            };
            if (elevated_exit) |exit_code| return exit_code;
        }
    } else if (!invocation.globals.ui_mode and needsElevation(invocation)) {
        const carries_aur = std.mem.eql(u8, invocation.command.path, aur_command_path);
        const elevated_arguments = if (carries_aur)
            try aur_url.argumentsWithEffectiveBase(context, invocation)
        else
            invocation.arguments;
        defer if (carries_aur) context.allocator.free(elevated_arguments);
        const elevated_exit = elevation.relaunchIfNeeded(context, elevated_arguments) catch |err| {
            try context.stderr.print("Unable to elevate install: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(context, invocation, Real{});
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    if (requestsStandardUpgrade(invocation) and !invocation.globals.no_confirm) {
        const confirmed = if (invocation.globals.ui_mode)
            try confirmStandardUpgradeUi(context)
        else
            try confirmStandardUpgrade(context);
        if (!confirmed) return 0;
    }

    const opening = try openingMessage(context.allocator, invocation);
    defer context.allocator.free(opening);
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner, opening)
    else
        executeStandard(context, invocation, runner, opening);
}

fn requestsStandardUpgrade(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) and
        optionEnabled(invocation, "--upgrade") and
        dependencyTargetCount(invocation) > 0;
}

fn confirmStandardUpgrade(context: *runtime.RuntimeContext) !bool {
    var result = list_updates.collectUpdates(context, .standard, .{}) catch |err| {
        try context.stderr.print("Unable to prepare the standard upgrade plan: {t}\n", .{err});
        try context.stderr.flush();
        return err;
    };
    defer result.deinit(context.allocator);

    const updates = switch (result) {
        .standard => |standard| standard.items,
        else => unreachable,
    };
    return confirmStandardUpgradeWithUpdates(context, updates);
}

fn confirmStandardUpgradeWithUpdates(
    context: *runtime.RuntimeContext,
    updates: []const list_updates.StandardUpdate,
) !bool {
    if (updates.len == 0) {
        try context.stdout.writeAll(
            "Standard packages are up to date. Continuing with the requested package installation.\n",
        );
        try context.stdout.flush();
        return true;
    }

    try writeStandardUpgradePreview(context.stdout, updates);
    const reader = context.stdin orelse {
        try context.stdout.writeAll("Operation cancelled: confirmation input is unavailable.\n");
        try context.stdout.flush();
        return false;
    };
    while (true) {
        try context.stdout.writeAll("Proceed with the standard system upgrade? (Y/n) ");
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse {
            try context.stdout.writeAll("\nOperation cancelled.\n");
            try context.stdout.flush();
            return false;
        };
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "y") or
            std.ascii.eqlIgnoreCase(answer, "yes"))
            return true;
        if (std.ascii.eqlIgnoreCase(answer, "n") or
            std.ascii.eqlIgnoreCase(answer, "no"))
        {
            try context.stdout.writeAll("Operation cancelled.\n");
            try context.stdout.flush();
            return false;
        }
        try context.stdout.writeAll("Please answer 'y' or 'n'.\n");
    }
}

fn confirmStandardUpgradeUi(context: *runtime.RuntimeContext) !bool {
    var result = list_updates.collectUpdates(context, .standard, .{}) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Unable to prepare the standard upgrade plan: {t}",
            .{err},
        );
        defer context.allocator.free(message);
        output.writeErrorFrame(context, message) catch {};
        ui_operation.flush(context) catch {};
        return err;
    };
    defer result.deinit(context.allocator);

    const updates = switch (result) {
        .standard => |standard| standard.items,
        else => unreachable,
    };
    return confirmStandardUpgradeUiWithUpdates(context, updates);
}

fn confirmStandardUpgradeUiWithUpdates(
    context: *runtime.RuntimeContext,
    updates: []const list_updates.StandardUpdate,
) !bool {
    if (updates.len == 0) {
        try output.writeInfoFrame(
            context,
            "Standard packages are up to date. Continuing with the requested package installation.",
        );
        try ui_operation.flush(context);
        return true;
    }

    var preview = std.Io.Writer.Allocating.init(context.allocator);
    defer preview.deinit();
    try writeStandardUpgradePreview(&preview.writer, updates);
    try output.writeInfoFrame(context, preview.writer.buffered());

    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    var question_responder: ui_operation.QuestionResponder = .{
        .context = context,
        .operation_context = &operation_context,
        .no_confirm = false,
    };
    question_responder.attach();
    defer question_responder.detach();

    var operation = operation_context.begin(.{
        .backend = .alpm,
        .kind = .update,
    });
    var answer = try operation.ask(.{
        .kind = .confirmation,
        .prompt = "Proceed with the standard system upgrade?",
        .default_response = .accepted,
    });
    defer answer.deinit(context.allocator);
    const accepted = answer.response == .accepted;
    operation.finish(if (accepted) .success else .cancelled);
    if (!accepted) try output.writeInfoFrame(context, "Operation cancelled.");
    try ui_operation.flush(context);
    return accepted;
}

fn writeStandardUpgradePreview(
    writer: *std.Io.Writer,
    updates: []const list_updates.StandardUpdate,
) !void {
    try writer.print(
        "WARNING: --upgrade will perform a full standard system upgrade before installing the " ++
            "requested packages.\n\nThe following {d} standard package{s} will be upgraded:\n",
        .{ updates.len, if (updates.len == 1) "" else "s" },
    );
    for (updates) |update| {
        try writer.print(
            "  {s}/{s}: {s} -> {s}\n",
            .{
                if (update.repository.len == 0) "unknown" else update.repository,
                update.name,
                update.current_version,
                update.new_version,
            },
        );
    }
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
    opening: []const u8,
) anyerror!u8 {
    const succeeded = try standard_single_pane.output(
        context,
        opening,
        invocation.globals.no_confirm,
        runner,
        invocation,
        null,
        null,
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
    opening: []const u8,
) anyerror!u8 {
    return ui_operation.runTransaction(context, invocation, .{
        .opening = opening,
        .success_message = successMessage(invocation),
        .failure_message = failureMessage(invocation),
        .failure_label = "Installation failed",
        .cancelled_message = "Installation cancelled.",
        .report_flatpak_unavailable = true,
    }, runner);
}

const PackageSource = union(enum) {
    repository: []const u8,
    file: []const u8,
    url: []const u8,
};

fn runStandard(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var repository_packages: std.ArrayList([]const u8) = .empty;
    defer repository_packages.deinit(context.allocator);
    var local_packages: std.ArrayList([]const u8) = .empty;
    defer local_packages.deinit(context.allocator);
    var downloaded_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (downloaded_paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(context.io, path) catch {};
            context.allocator.free(path);
        }
        downloaded_paths.deinit(context.allocator);
    }

    for (invocation.positionals) |value| switch (classifyPackageSource(value)) {
        .repository => |name| try repository_packages.append(context.allocator, name),
        .file => |path| try local_packages.append(context.allocator, path),
        .url => |url| {
            const path = try downloadPackage(context, operation_context, url);
            try downloaded_paths.append(context.allocator, path);
            try local_packages.append(context.allocator, path);
        },
    };

    if (optionEnabled(invocation, "--build-deps") and repository_packages.items.len > 1)
        return error.MultipleDependencyTargets;

    if (repository_packages.items.len > 0)
        try installRepositoryPackages(context, operation_context, invocation, repository_packages.items);
    for (local_packages.items) |path|
        try installLocalPackage(context, operation_context, path);
}

fn installRepositoryPackages(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
    package_names: []const []const u8,
) !void {
    const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, .{ .use_root = true, .operation_context = operation_context });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    if (optionEnabled(invocation, "--upgrade")) {
        try manager.sync(false);
        const updates = try manager.get_updates_available();
        defer Zigalpm.alpm.OwnedPackageWithUpdate.deinitSlice(context.allocator, updates);
        if (updates.len > 0) {
            var restart_report = try manager.sync_system_update(.{});
            restart_report.deinit();
        }
    }

    const names = try sentinelStrings(context.allocator, package_names);
    defer freeSentinelStrings(context.allocator, names);
    if (optionEnabled(invocation, "--build-deps")) {
        try manager.install_dependencies_only(
            names[0],
            optionEnabled(invocation, "--make-deps"),
            .{},
        );
        return;
    }
    try manager.install_packages(
        names,
        if (optionEnabled(invocation, "--no-deps")) .{ .nodeps = true } else .{},
    );
}

fn installLocalPackage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    location: []const u8,
) !void {
    std.Io.Dir.cwd().access(context.io, location, .{}) catch return error.FileNotFound;
    const current_directory = try std.process.currentPathAlloc(context.io, context.allocator);
    defer context.allocator.free(current_directory);
    const absolute_path = try std.fs.path.resolve(context.allocator, &.{ current_directory, location });
    defer context.allocator.free(absolute_path);
    const inspector: Zigalpm.local.Inspector = .{ .allocator = context.allocator, .io = context.io };

    if (try inspector.isArchPackage(absolute_path)) {
        const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, .{ .use_root = true, .operation_context = operation_context });
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);
        try manager.install_local_packages(&.{absolute_path}, .{});
        return;
    }
    if (try inspector.isBinariesPackage(absolute_path)) {
        var manager = Zigalpm.LocalManager.init(context.allocator, context.io, .{});
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);
        if (!try manager.installBinariesPackage(absolute_path)) return InstallError.BackendFailed;
        return;
    }
    return InstallError.UnsupportedLocalPackage;
}

fn downloadPackage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    url: []const u8,
) ![]const u8 {
    var random: [8]u8 = undefined;
    context.io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const file_name = urlFileName(url);
    const destination = try std.fmt.allocPrint(
        context.allocator,
        "/tmp/shelly-install-{s}-{s}",
        .{ suffix[0..8], file_name },
    );
    errdefer {
        std.Io.Dir.cwd().deleteFile(context.io, destination) catch {};
        context.allocator.free(destination);
    }

    var downloader = Zigalpm.shared.Downloader.init(
        context.allocator,
        context.io,
        Zigalpm.shared.downloader.DownloadConfiguration.default(),
    );
    defer downloader.deinit();
    downloader.setOperationContext(operation_context);
    return switch (downloader.downloadToFile(url, destination, true)) {
        .succes, .skipped => destination,
        .failure => InstallError.DownloadFailed,
    };
}

fn runAur(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (!isAurVersionInstall(invocation) and
        optionEnabled(invocation, "--build-deps") and invocation.positionals.len > 1)
        return error.MultipleDependencyTargets;
    const executable = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable);
    const build_command = std.mem.trimEnd(u8, executable, " (deleted)");
    const aur_base = try aur_url.resolveFor(context, invocation);
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .aur_git_base_url = aur_base,
        .root = true,
        .use_chroot = optionEnabled(invocation, "--chroot"),
        .check = checkOverride(invocation),
        .sign = signOverride(invocation),
        .build_command = build_command,
        .operation_context = operation_context,
    });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    if (isAurVersionInstall(invocation)) {
        try manager.installPackageVersion(invocation.positionals[0], invocation.positionals[1]);
    } else if (optionEnabled(invocation, "--build-deps")) {
        try manager.installDependenciesOnly(
            invocation.positionals[0],
            optionEnabled(invocation, "--make-deps"),
        );
    } else {
        try manager.installPackages(invocation.positionals);
    }
}

fn checkOverride(invocation: *const parser.Invocation) ?bool {
    if (optionEnabled(invocation, "--no-check")) return false;
    if (optionEnabled(invocation, "--check")) return true;
    return null;
}

fn signOverride(invocation: *const parser.Invocation) ?bool {
    if (optionEnabled(invocation, "--nosign")) return false;
    if (optionEnabled(invocation, "--sign")) return true;
    return null;
}

fn runAppImage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (elevation.isRoot()) {
        const args = try appimageInstallArgs(context.allocator, invocation);
        defer context.allocator.free(args);
        if (try elevation.runAsInvokingUser(context, args)) |exit_code| {
            if (exit_code != 0) return InstallError.BackendFailed;
            return;
        }
        // A direct root invocation has no user to re-launch as. Continue
        // with root's own user-scoped AppImage store in that case.
    }

    const location = invocation.positionals[0];
    std.Io.Dir.cwd().access(context.io, location, .{}) catch return error.FileNotFound;
    if (!Zigalpm.AppImageManager.isAppImage(location)) return error.NotAnAppImage;

    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = optionValue(invocation, "--install-path") orelse
        stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    var manager = Zigalpm.AppImageManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    if (!try manager.installAppImage(location)) return InstallError.BackendFailed;
}

fn appimageInstallArgs(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "install", "appimage" });
    if (invocation.globals.no_confirm)
        try args.append(allocator, "--no-confirm");
    if (invocation.globals.json)
        try args.append(allocator, "--json");
    if (invocation.globals.ui_mode)
        try args.append(allocator, "--ui-mode");
    if (optionValue(invocation, "--install-path")) |install_path|
        try args.appendSlice(allocator, &.{ "--install-path", install_path });
    for (invocation.positionals) |positional| try args.append(allocator, positional);
    return args.toOwnedSlice(allocator);
}

const FlatpakCandidate = struct {
    id: []const u8,
    name: []const u8,
    remote: []const u8,
};

const EolInstallReplacement = struct {
    id: []u8,
    branch: []u8,

    fn deinit(self: *EolInstallReplacement, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.branch);
        self.* = undefined;
    }
};

fn resolveFlatpakEolInstallTarget(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    manager: anytype,
    selected_id: []const u8,
    selected_remote: []const u8,
    requested_branch: []const u8,
    requested_scope: Zigalpm.flatpak.Scope,
) !?EolInstallReplacement {
    var remote_ref = manager.get_remote_ref_info_flatpak(
        selected_remote,
        selected_id,
        requested_branch,
        requested_scope,
    ) catch return null;
    defer remote_ref.deinit(context.allocator);

    const marker = remote_ref.eol_rebase orelse {
        if (remote_ref.eol) |reason| {
            const warning = try Zigalpm.flatpak.eol.eolOnlyWarning(
                context.allocator,
                selected_id,
                requested_branch,
                reason,
            );
            defer context.allocator.free(warning);
            Zigalpm.flatpak.eol.emitStatus(operation_context, .install, .warning, selected_id, warning);
        }
        return null;
    };

    const target = Zigalpm.flatpak.eol.parseRebaseTarget(marker, requested_branch) orelse {
        const warning = try Zigalpm.flatpak.eol.eolOnlyWarning(
            context.allocator,
            selected_id,
            requested_branch,
            remote_ref.eol,
        );
        defer context.allocator.free(warning);
        Zigalpm.flatpak.eol.emitStatus(operation_context, .install, .warning, selected_id, warning);
        return null;
    };

    const owned_id = try context.allocator.dupe(u8, target.id);
    errdefer context.allocator.free(owned_id);
    const owned_branch = try context.allocator.dupe(u8, target.branch);
    errdefer context.allocator.free(owned_branch);

    const notice = try std.fmt.allocPrint(
        context.allocator,
        "{s} is end-of-life; installing replacement {s} instead.",
        .{ selected_id, target.id },
    );
    defer context.allocator.free(notice);
    Zigalpm.flatpak.eol.emitStatus(operation_context, .install, .information, selected_id, notice);

    return .{ .id = owned_id, .branch = owned_branch };
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const requested_scope: Zigalpm.flatpak.Scope =
        if (optionEnabled(invocation, "--user")) .user else .system;
    const requested_id = invocation.positionals[0];
    var selected_id: []const u8 = requested_id;
    var selected_remote: []const u8 = optionValue(invocation, "--remote") orelse "";
    var owned_remote: ?[]const u8 = null;
    defer if (owned_remote) |remote| context.allocator.free(remote);

    var catalogs: ?[]Zigalpm.flatpak.AppstreamCatalog = null;
    defer if (catalogs) |values|
        Zigalpm.flatpak.AppstreamCatalog.deinitSlice(context.allocator, values);
    if (selected_remote.len == 0 and std.mem.indexOfScalar(u8, requested_id, '.') == null) {
        var appstreams = Zigalpm.flatpak.AppstreamManager.init(context.allocator, context.io);
        appstreams.setOperationContext(operation_context);
        catalogs = appstreams.getAllRemoteCatalogs(null) catch null;
        var candidates: std.ArrayList(FlatpakCandidate) = .empty;
        defer candidates.deinit(context.allocator);
        for (catalogs orelse &.{}) |catalog| {
            if (catalog.scope != requested_scope) continue;
            for (catalog.apps) |application| {
                const partial = containsIgnoreCase(application.id, requested_id) or
                    containsIgnoreCase(application.name, requested_id);
                if (!partial) continue;
                try candidates.append(context.allocator, .{
                    .id = application.id,
                    .name = application.name,
                    .remote = catalog.remote_name,
                });
            }
        }
        if (candidates.items.len > 0) {
            const selected = try selectFlatpakCandidate(context, operation_context, candidates.items);
            selected_id = selected.id;
            selected_remote = selected.remote;
        }
    }
    if (selected_remote.len == 0) {
        owned_remote = try firstFlatpakRemote(context, operation_context, requested_scope);
        selected_remote = owned_remote orelse "";
    }
    if (selected_remote.len == 0) return InstallError.NoFlatpakRemote;

    const requested_branch = optionValue(invocation, "--branch") orelse "";

    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};

    var eol_replacement: ?EolInstallReplacement = null;
    if (!optionEnabled(invocation, "--runtime")) {
        eol_replacement = resolveFlatpakEolInstallTarget(
            context,
            operation_context,
            manager,
            selected_id,
            selected_remote,
            requested_branch,
            requested_scope,
        ) catch null;
    }
    defer if (eol_replacement) |*replacement| replacement.deinit(context.allocator);

    const install_id = if (eol_replacement) |replacement| replacement.id else selected_id;
    const install_branch = if (eol_replacement) |replacement| replacement.branch else requested_branch;

    const id_z = try context.allocator.dupeZ(u8, install_id);
    defer context.allocator.free(id_z);
    const remote_z = try context.allocator.dupeZ(u8, selected_remote);
    defer context.allocator.free(remote_z);
    const branch_z = try context.allocator.dupeZ(u8, install_branch);
    defer context.allocator.free(branch_z);
    if (!try manager.install_flatpak(
        id_z,
        remote_z,
        requested_scope,
        branch_z,
        optionEnabled(invocation, "--runtime"),
    )) return InstallError.BackendFailed;
}

fn runFlatpakRepair(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    if (!try manager.repair_installed_flatpak(invocation.positionals[0]))
        return InstallError.BackendFailed;
}

fn repairTargetRequiresElevation(context: *runtime.RuntimeContext, target: []const u8) !bool {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    var application = (try manager.find_installed_flatpak(target)) orelse return false;
    defer application.deinit(context.allocator);
    return repairScopeRequiresElevation(application.scope, elevation.isRoot());
}

fn repairScopeRequiresElevation(
    scope: Zigalpm.flatpak.Scope,
    running_as_root: bool,
) bool {
    return !running_as_root and scope == .system;
}

const FlatpakFileKind = enum {
    ref_file,
    bundle,
};

fn runFlatpakFile(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
    kind: FlatpakFileKind,
) !void {
    const location = invocation.positionals[0];
    std.Io.Dir.cwd().access(context.io, location, .{}) catch return error.FileNotFound;
    const current_directory = try std.process.currentPathAlloc(context.io, context.allocator);
    defer context.allocator.free(current_directory);
    const absolute_path = try std.fs.path.resolve(context.allocator, &.{ current_directory, location });
    defer context.allocator.free(absolute_path);
    const path_z = try context.allocator.dupeZ(u8, absolute_path);
    defer context.allocator.free(path_z);

    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    const installed = switch (kind) {
        .ref_file => try manager.install_from_ref_flatpak(path_z, flatpakFileScope(invocation)),
        .bundle => try manager.install_from_bundle_flatpak(path_z, flatpakFileScope(invocation)),
    };
    if (!installed) return InstallError.BackendFailed;
}

fn flatpakFileScope(invocation: *const parser.Invocation) Zigalpm.flatpak.Scope {
    return if (optionEnabled(invocation, "--user")) .user else .system;
}

fn flatpakFileKind(invocation: *const parser.Invocation) ?FlatpakFileKind {
    if (!std.mem.eql(u8, invocation.command.path, flatpak_command_path)) return null;
    if (optionEnabled(invocation, "--ref-file")) return .ref_file;
    if (optionEnabled(invocation, "--bundle")) return .bundle;
    return null;
}

fn firstFlatpakRemote(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    requested_scope: Zigalpm.flatpak.Scope,
) !?[]const u8 {
    var manager = Zigalpm.flatpak.RemoteManager{ .allocator = context.allocator, .io = context.io };
    manager.setOperationContext(operation_context);
    const remotes = try manager.listRemotesWithDetails();
    defer Zigalpm.flatpak.Remote.deinitSlice(
        context.allocator,
        remotes,
    );
    for (remotes) |remote| {
        if (remote.scope != requested_scope or remote.disabled) continue;
        const name = remote.name;
        if (name.len > 0) return try context.allocator.dupe(u8, name);
    }
    return null;
}

fn selectFlatpakCandidate(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    candidates: []const FlatpakCandidate,
) !FlatpakCandidate {
    if (candidates.len == 1) return candidates[0];
    const options = try context.allocator.alloc(Zigalpm.OperationQuestionOption, candidates.len);
    defer context.allocator.free(options);
    const labels = try context.allocator.alloc([]const u8, candidates.len);
    var initialized_labels: usize = 0;
    defer {
        for (labels[0..initialized_labels]) |label| context.allocator.free(label);
        context.allocator.free(labels);
    }
    for (candidates, options, labels) |candidate, *option, *label| {
        label.* = try std.fmt.allocPrint(context.allocator, "{s} ({s}) [{s}]", .{
            candidate.name,
            candidate.id,
            candidate.remote,
        });
        initialized_labels += 1;
        option.* = .{ .id = candidate.id, .label = label.* };
    }
    var operation = operation_context.begin(.{
        .backend = .flatpak,
        .kind = .search,
        .subject = candidates[0].id,
    });
    defer operation.finish(.success);
    var response = try operation.ask(.{
        .kind = .select_one,
        .prompt = "Select a package to install:",
        .options = options,
        .default_response = .{ .choice = 0 },
    });
    defer response.deinit(context.allocator);
    const index = switch (response.response) {
        .choice => |value| value,
        else => 0,
    };
    return candidates[if (index < candidates.len) index else 0];
}

fn reportValidationFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
    } else {
        try output.writeFailure(context, message);
    }
    try ui_operation.flush(context);
    return 1;
}

fn openingMessage(allocator: std.mem.Allocator, invocation: *const parser.Invocation) ![]const u8 {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path))
    {
        if (isAurVersionInstall(invocation))
            return std.fmt.allocPrint(
                allocator,
                "Installing AUR package {s} at commit {s}",
                .{ invocation.positionals[0], invocation.positionals[1] },
            );
        const names = try format.joined(allocator, invocation.positionals);
        defer allocator.free(names);
        if (std.mem.eql(u8, invocation.command.path, standard_command_path))
            return std.fmt.allocPrint(allocator, "Installing packages: {s}", .{names});
        return std.fmt.allocPrint(allocator, "Installing AUR packages: {s}", .{names});
    }
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return std.fmt.allocPrint(allocator, "Installing AppImage: {s}", .{invocation.positionals[0]});
    if (isFlatpakRepair(invocation))
        return std.fmt.allocPrint(allocator, "Repairing Flatpak: {s}...", .{invocation.positionals[0]});
    if (flatpakFileKind(invocation)) |kind| return switch (kind) {
        .ref_file => std.fmt.allocPrint(
            allocator,
            "Installing Flatpak ref file: {s}",
            .{invocation.positionals[0]},
        ),
        .bundle => std.fmt.allocPrint(
            allocator,
            "Installing Flatpak bundle: {s}",
            .{invocation.positionals[0]},
        ),
    };
    return std.fmt.allocPrint(allocator, "Installing Flatpak: {s}", .{invocation.positionals[0]});
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return "Packages installed successfully!";
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return if (optionEnabled(invocation, "--build-deps"))
            "Dependencies installed successfully!"
        else
            "Installation complete.";
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return "Successfully installed appimage.";
    if (isFlatpakRepair(invocation)) return "Flatpak repaired successfully!";
    return "Flatpak install complete.";
}

fn failureMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, aur_command_path) and
        optionEnabled(invocation, "--build-deps")) return "Dependency installation failed.";
    if (isFlatpakRepair(invocation)) return "Flatpak repair failed.";
    return "Installation failed.";
}

fn classifyPackageSource(value: []const u8) PackageSource {
    if (isUrl(value)) return .{ .url = value };
    if (isRepositoryQualifiedName(value)) return .{ .repository = value };
    if (std.mem.indexOfScalar(u8, value, '/') != null or
        std.mem.indexOfScalar(u8, value, '\\') != null or
        std.mem.startsWith(u8, value, "~") or
        std.fs.path.isAbsolute(value) or
        Zigalpm.local.file_inspector.isSupportedArchive(value)) return .{ .file = value };
    return .{ .repository = value };
}

fn isUrl(value: []const u8) bool {
    return startsWithIgnoreCase(value, "http://") or
        startsWithIgnoreCase(value, "https://") or
        startsWithIgnoreCase(value, "ftp://");
}

fn isRepositoryQualifiedName(value: []const u8) bool {
    if (value.len == 0 or value[0] == '~' or std.fs.path.isAbsolute(value)) return false;
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    if (slash == 0 or slash + 1 >= value.len or std.mem.indexOfScalarPos(u8, value, slash + 1, '/') != null)
        return false;
    if (std.fs.path.extension(value[slash + 1 ..]).len > 0) return false;
    for (value) |character| {
        if (character == '/') continue;
        if (!std.ascii.isAlphanumeric(character) and
            character != '-' and character != '_' and character != '.' and
            character != '+' and character != '@') return false;
    }
    return true;
}

fn urlFileName(url: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |index| path[index + 1 ..] else path;
    return if (name.len == 0) "package-download" else name;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn sentinelStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][:0]const u8 {
    const result = try allocator.alloc([:0]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, result) |value, *destination| {
        destination.* = try allocator.dupeZ(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeSentinelStrings(allocator: std.mem.Allocator, values: [][:0]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

fn isAurVersionInstall(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, aur_command_path) and
        optionEnabled(invocation, "--version");
}

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn isInstallPath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, appimage_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

fn needsPackages(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path);
}

fn dependencyTargetCount(invocation: *const parser.Invocation) usize {
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return invocation.positionals.len;
    if (!std.mem.eql(u8, invocation.command.path, standard_command_path)) return 0;
    var count: usize = 0;
    for (invocation.positionals) |value| switch (classifyPackageSource(value)) {
        .repository => count += 1,
        .file, .url => {},
    };
    return count;
}

fn needsElevation(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path) or
        (std.mem.eql(u8, invocation.command.path, flatpak_command_path) and
            !isFlatpakRepair(invocation) and
            !optionEnabled(invocation, "--user"));
}

fn isFlatpakRepair(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, flatpak_command_path) and
        optionEnabled(invocation, "--repair");
}

test "Flatpak repair is an install modifier with f shortcode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--repair", "org.example.App" },
    );
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isFlatpakRepair(&outcome.dispatch));
    try std.testing.expect(!needsElevation(&outcome.dispatch));

    const translated = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{ "-Iff", "org.example.App" },
    );
    outcome = try parser.parse(arena.allocator(), &manifest, translated.arguments().?);
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isFlatpakRepair(&outcome.dispatch));
    try std.testing.expectEqualStrings("org.example.App", outcome.dispatch.positionals[0]);
}

test "Flatpak repair rejects install source modifiers" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--repair", "--remote", "flathub", "org.example.App" },
    );
    try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Cannot combine --repair with",
    ) != null);
}

test "Flatpak repair lifecycle and elevation follow the installed scope" {
    try std.testing.expect(repairScopeRequiresElevation(.system, false));
    try std.testing.expect(!repairScopeRequiresElevation(.user, false));
    try std.testing.expect(!repairScopeRequiresElevation(.system, true));

    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--repair", "org.example.App" },
    );
    const Capture = struct {
        called: bool = false,

        pub fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            invocation: *const parser.Invocation,
        ) !void {
            self.called = true;
            try std.testing.expect(isFlatpakRepair(invocation));
        }
    };
    var capture: Capture = .{};
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expect(capture.called);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Repairing Flatpak: org.example.App",
    ) != null);
}

test "Flatpak file install modifiers use the shared command and scope" {
    try std.testing.expect(isInstallPath(flatpak_command_path));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--ref-file", "/tmp/demo.flatpakref" },
    );
    try std.testing.expect(flatpakFileKind(&outcome.dispatch) == .ref_file);
    try std.testing.expect(flatpakFileScope(&outcome.dispatch) == .system);
    try std.testing.expect(needsElevation(&outcome.dispatch));
    try std.testing.expectEqualStrings("/tmp/demo.flatpakref", outcome.dispatch.positionals[0]);

    outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--ref-file", "--user", "demo.flatpakref" },
    );
    try std.testing.expect(flatpakFileKind(&outcome.dispatch) == .ref_file);
    try std.testing.expect(flatpakFileScope(&outcome.dispatch) == .user);
    try std.testing.expect(!needsElevation(&outcome.dispatch));

    outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--bundle", "demo.flatpak" },
    );
    try std.testing.expect(flatpakFileKind(&outcome.dispatch) == .bundle);
    try std.testing.expect(flatpakFileScope(&outcome.dispatch) == .system);
    try std.testing.expect(needsElevation(&outcome.dispatch));

    const old_ref = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "install-ref-file", "flatpak", "demo.flatpakref" },
    );
    try std.testing.expect(old_ref == .dispatch);
    try std.testing.expectEqualStrings("shelly", old_ref.dispatch.command.path);
    const old_bundle = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "install-bundle", "flatpak", "demo.flatpak" },
    );
    try std.testing.expect(old_bundle == .dispatch);
    try std.testing.expectEqualStrings("shelly", old_bundle.dispatch.command.path);
}

test "Flatpak file install modifiers reject conflicting modes and repository options" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--ref-file", "--bundle", "demo.flatpak" },
    );
    try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Choose exactly one of --ref-file or --bundle.",
    ) != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "flatpak", "--ref-file", "--remote", "flathub", "demo.flatpakref" },
    );
    try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Cannot combine --ref-file or --bundle with --remote, --branch, or --runtime.",
    ) != null);
}

test "install routes every action-first backend and forwards type-specific options" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Capture = struct {
        calls: usize = 0,
        paths: [6][]const u8 = undefined,

        pub fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            invocation: *const parser.Invocation,
        ) !void {
            self.paths[self.calls] = invocation.command.path;
            self.calls += 1;
            if (std.mem.eql(u8, invocation.command.path, standard_command_path))
                try std.testing.expect(optionEnabled(invocation, "--no-deps"));
            if (std.mem.eql(u8, invocation.command.path, aur_command_path))
                try std.testing.expect(optionEnabled(invocation, "--chroot"));
            if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) {
                if (flatpakFileKind(invocation)) |kind| {
                    if (kind == .ref_file)
                        try std.testing.expect(flatpakFileScope(invocation) == .user)
                    else
                        try std.testing.expect(flatpakFileScope(invocation) == .system);
                } else {
                    try std.testing.expectEqualStrings("flathub-beta", optionValue(invocation, "--remote").?);
                    try std.testing.expectEqualStrings("beta", optionValue(invocation, "--branch").?);
                }
            }
        }
    };
    var capture: Capture = .{};
    const arguments = [_][]const []const u8{
        &.{ "install", "standard", "--no-deps", "demo" },
        &.{ "install", "appimage", "demo.AppImage" },
        &.{ "install", "aur", "--chroot", "demo-git" },
        &.{ "install", "flatpak", "--user", "--remote", "flathub-beta", "--branch", "beta", "org.demo.App" },
        &.{ "install", "flatpak", "--ref-file", "--user", "demo.flatpakref" },
        &.{ "install", "flatpak", "--bundle", "demo.flatpak" },
    };
    for (arguments) |argv| {
        const outcome = try parser.parse(tc.arena.allocator(), &manifest, argv);
        const invocation = outcome.dispatch;
        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &invocation, &capture));
    }
    try std.testing.expectEqual(@as(usize, 6), capture.calls);
    try std.testing.expectEqualStrings(standard_command_path, capture.paths[0]);
    try std.testing.expectEqualStrings(appimage_command_path, capture.paths[1]);
    try std.testing.expectEqualStrings(aur_command_path, capture.paths[2]);
    try std.testing.expectEqualStrings(flatpak_command_path, capture.paths[3]);
    try std.testing.expectEqualStrings(flatpak_command_path, capture.paths[4]);
    try std.testing.expectEqualStrings(flatpak_command_path, capture.paths[5]);
}

test "AUR version install uses exact package and commit through the shared lifecycle" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "install",
        "aur",
        "--version",
        "--check",
        "demo-git",
        "deadbeef",
    });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isAurVersionInstall(&outcome.dispatch));

    const Capture = struct {
        pub fn run(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            invocation: *const parser.Invocation,
        ) !void {
            try std.testing.expect(isAurVersionInstall(invocation));
            try std.testing.expect(optionEnabled(invocation, "--check"));
            try std.testing.expectEqualStrings("demo-git", invocation.positionals[0]);
            try std.testing.expectEqualStrings("deadbeef", invocation.positionals[1]);
        }
    };
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&tc.context, &outcome.dispatch, Capture{}),
    );
    const rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "Installing AUR package demo-git at commit deadbeef",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":: Transaction complete.") != null);
}

test "AUR version install validates package commit and incompatible dependency mode" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "aur", "--version", "demo-git" },
    );
    try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "No commit specified.") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "install",
        "aur",
        "--version",
        "--build-deps",
        "demo-git",
        "deadbeef",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Cannot combine --version with dependency-only installation options.",
    ) != null);
}

test "install uses the shared non-UI and UI transaction lifecycles" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Success = struct {
        pub fn run(_: @This(), _: *runtime.RuntimeContext, operation_context: *Zigalpm.OperationContext, invocation: *const parser.Invocation) !void {
            if (!invocation.globals.ui_mode) return;
            var operation = operation_context.begin(.{
                .backend = .aur,
                .kind = .build,
                .subject = "demo",
            });
            defer operation.finish(.success);
            operation.progress(.{ .percentage = 42, .native_code = 200 });
        }
    };

    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "install", "standard", "demo" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, Success{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), ":: Installing packages: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), ":: Transaction complete.") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "install", "aur", "--ui-mode", "demo" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, Success{}));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));
}

test "standard install upgrade requires confirmation unless disabled" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var declined_input = std.Io.Reader.fixed("n\n");
    tc.context.stdin = &declined_input;
    const Capture = struct {
        called: bool = false,

        pub fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: *const parser.Invocation,
        ) !void {
            self.called = true;
        }
    };
    var capture: Capture = .{};
    const updates = [_]list_updates.StandardUpdate{.{
        .name = "linux",
        .current_version = "6.12.1-1",
        .new_version = "6.12.2-1",
        .download_size = 1024,
        .size_difference = 256,
        .description = "",
        .url = "",
        .repository = "core",
        .installed_size = 4096,
        .depends = &.{},
        .optional_depends = &.{},
        .licenses = &.{},
        .provides = &.{},
        .conflicts = &.{},
        .groups = &.{},
    }};

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "standard", "--upgrade", "demo" },
    );
    try std.testing.expect(requestsStandardUpgrade(&outcome.dispatch));
    try std.testing.expect(!try confirmStandardUpgradeWithUpdates(&tc.context, &updates));
    try std.testing.expect(!capture.called);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "core/linux: 6.12.1-1 -> 6.12.2-1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Proceed with the standard system upgrade? (Y/n)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Operation cancelled.") != null);

    tc.stdout.writer.end = 0;
    var accepted_input = std.Io.Reader.fixed("\n");
    tc.context.stdin = &accepted_input;
    try std.testing.expect(try confirmStandardUpgradeWithUpdates(&tc.context, &updates));

    tc.context.stdin = null;
    outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "standard", "--upgrade", "--no-confirm", "demo" },
    );
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expect(capture.called);

    outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "install", "standard", "--upgrade", "demo.pkg.tar.zst" },
    );
    try std.testing.expect(!requestsStandardUpgrade(&outcome.dispatch));
}

test "standard install upgrade CLI skips confirmation when packages are current" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = null,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expect(try confirmStandardUpgradeWithUpdates(&context, &.{}));
    try std.testing.expect(std.mem.indexOf(
        u8,
        stdout.writer.buffered(),
        "Standard packages are up to date.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stdout.writer.buffered(),
        "Proceed with the standard system upgrade?",
    ) == null);
}

test "standard install upgrade UI previews available updates before confirmation" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const response_json = "{\"$kind\":\"a.yesno\",\"QuestionId\":\"1\",\"Accept\":true}";
    const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
    const encoded = try tc.arena.allocator().alloc(u8, encoded_size);
    const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
    const response_frame = try std.fmt.allocPrint(
        tc.arena.allocator(),
        "[JSON]{s}[/JSON]\n",
        .{encoded_response},
    );
    var stdin = std.Io.Reader.fixed(response_frame);
    tc.context.stdin = &stdin;

    const updates = [_]list_updates.StandardUpdate{
        .{
            .name = "linux",
            .current_version = "6.12.1-1",
            .new_version = "6.12.2-1",
            .download_size = 1024,
            .size_difference = 256,
            .description = "",
            .url = "",
            .repository = "core",
            .installed_size = 4096,
            .depends = &.{},
            .optional_depends = &.{},
            .licenses = &.{},
            .provides = &.{},
            .conflicts = &.{},
            .groups = &.{},
        },
        .{
            .name = "firefox",
            .current_version = "127.0-1",
            .new_version = "128.0-1",
            .download_size = 2048,
            .size_difference = -128,
            .description = "",
            .url = "",
            .repository = "extra",
            .installed_size = 8192,
            .depends = &.{},
            .optional_depends = &.{},
            .licenses = &.{},
            .provides = &.{},
            .conflicts = &.{},
            .groups = &.{},
        },
    };

    try std.testing.expect(try confirmStandardUpgradeUiWithUpdates(&tc.context, &updates));
    const rendered = tc.stdout.writer.buffered();
    var frame_iterator = std.mem.splitSequence(u8, rendered, "[JSON]");
    _ = frame_iterator.next();
    var found_preview = false;
    var found_confirmation = false;
    while (frame_iterator.next()) |framed| {
        const encoded_end = std.mem.indexOf(u8, framed, "[/JSON]") orelse continue;
        const payload = framed[0..encoded_end];
        const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const decoded = try tc.arena.allocator().alloc(u8, decoded_size);
        try std.base64.standard.Decoder.decode(decoded, payload);
        if (std.mem.indexOf(u8, decoded, "core/linux: 6.12.1-1 -> 6.12.2-1") != null and
            std.mem.indexOf(u8, decoded, "extra/firefox: 127.0-1 -> 128.0-1") != null)
        {
            found_preview = true;
        }
        if (std.mem.indexOf(u8, decoded, "\"$kind\":\"q.yesno\"") == null) continue;
        found_confirmation = true;
        try std.testing.expect(std.mem.indexOf(u8, decoded, "Proceed with the standard system upgrade?") != null);
    }
    try std.testing.expect(found_preview);
    try std.testing.expect(found_confirmation);

    tc.stdout.writer.end = 0;
    const decline_json = "{\"$kind\":\"a.yesno\",\"QuestionId\":\"1\",\"Accept\":false}";
    const decline_encoded_size = std.base64.standard.Encoder.calcSize(decline_json.len);
    const decline_encoded = try tc.arena.allocator().alloc(u8, decline_encoded_size);
    const decline_response = std.base64.standard.Encoder.encode(decline_encoded, decline_json);
    const decline_frame = try std.fmt.allocPrint(
        tc.arena.allocator(),
        "[JSON]{s}[/JSON]\n",
        .{decline_response},
    );
    var decline_input = std.Io.Reader.fixed(decline_frame);
    tc.context.stdin = &decline_input;
    try std.testing.expect(!try confirmStandardUpgradeUiWithUpdates(&tc.context, &updates));
}

test "standard install upgrade UI skips confirmation when packages are current" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = null,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expect(try confirmStandardUpgradeUiWithUpdates(&context, &.{}));

    var frame_iterator = std.mem.splitSequence(u8, stdout.writer.buffered(), "[JSON]");
    _ = frame_iterator.next();
    var found_up_to_date = false;
    var found_confirmation = false;
    while (frame_iterator.next()) |framed| {
        const encoded_end = std.mem.indexOf(u8, framed, "[/JSON]") orelse continue;
        const payload = framed[0..encoded_end];
        const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const decoded = try arena.allocator().alloc(u8, decoded_size);
        try std.base64.standard.Decoder.decode(decoded, payload);
        if (std.mem.indexOf(u8, decoded, "Standard packages are up to date.") != null)
            found_up_to_date = true;
        if (std.mem.indexOf(u8, decoded, "\"$kind\":\"q.yesno\"") != null)
            found_confirmation = true;
    }
    try std.testing.expect(found_up_to_date);
    try std.testing.expect(!found_confirmation);
}

test "install backend failures return a failing exit code and transaction result" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "install", "standard", "demo" });
    const Failure = struct {
        pub fn run(_: @This(), _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
            return error.TestInstallFailure;
        }
    };
    try std.testing.expectEqual(
        @as(u8, 1),
        try executeWithRunner(&tc.context, &outcome.dispatch, Failure{}),
    );
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Technical details: TestInstallFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), ":: Transaction failed.") != null);
}

test "standard source classification preserves dotted repository names files and URLs" {
    try std.testing.expect(classifyPackageSource("core/linux") == .repository);
    try std.testing.expect(classifyPackageSource("linux") == .repository);
    try std.testing.expect(classifyPackageSource("dotnet-sdk-8.0") == .repository);
    try std.testing.expect(classifyPackageSource("./demo.pkg.tar.zst") == .file);
    try std.testing.expect(classifyPackageSource("demo.pkg.tar.zst") == .file);
    try std.testing.expect(classifyPackageSource("https://example.test/demo.pkg.tar.zst") == .url);
    try std.testing.expectEqualStrings("demo.pkg.tar.zst", urlFileName("https://example.test/demo.pkg.tar.zst?token=1"));
}

test "Flatpak candidate selection uses the shared question response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operations = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operations.deinit();
    operations.setQuestionHandler(.{ .function = struct {
        fn answer(_: ?*anyopaque, _: Zigalpm.OperationQuestion) Zigalpm.OperationQuestionResponse {
            return .{ .choice = 1 };
        }
    }.answer });
    const selected = try selectFlatpakCandidate(&context, &operations, &.{
        .{ .id = "org.demo.One", .name = "One", .remote = "flathub" },
        .{ .id = "org.demo.Two", .name = "Two", .remote = "flathub-beta" },
    });
    try std.testing.expectEqualStrings("org.demo.Two", selected.id);
    try std.testing.expectEqualStrings("flathub-beta", selected.remote);
}

const EolInstallTestManager = struct {
    allocator: std.mem.Allocator,
    remote_ref: ?Zigalpm.flatpak.types.RemoteRef = null,
    fetch_error: bool = false,

    pub fn get_remote_ref_info_flatpak(
        self: @This(),
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: Zigalpm.flatpak.Scope,
    ) !Zigalpm.flatpak.types.RemoteRef {
        if (self.fetch_error) return error.TestFetchFailure;
        const source = self.remote_ref orelse return error.TestFetchFailure;
        return Zigalpm.flatpak.types.RemoteRef.fromWire(self.allocator, .{
            .remote_name = source.remote_name,
            .installed_size = source.installed_size,
            .download_size = source.download_size,
            .eol = source.eol,
            .eol_rebase = source.eol_rebase,
            .scope = Zigalpm.flatpak.types.Scope.toWire(source.scope),
            .permissions = &.{},
        });
    }
};

fn makeEolRemoteRef(eol: ?[]const u8, eol_rebase: ?[]const u8) Zigalpm.flatpak.types.RemoteRef {
    return .{
        .remote_name = @constCast("flathub"),
        .installed_size = 0,
        .download_size = 0,
        .eol = if (eol) |value| @constCast(value) else null,
        .eol_rebase = if (eol_rebase) |value| @constCast(value) else null,
        .scope = .system,
        .permissions = &.{},
    };
}

test "Flatpak install EOL detection redirects to the replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operations = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operations.deinit();

    var manager: EolInstallTestManager = .{
        .allocator = arena.allocator(),
        .remote_ref = makeEolRemoteRef(null, "no.bragefuglseth.Keypunch"),
    };
    _ = &manager;

    var replacement = try resolveFlatpakEolInstallTarget(
        &context,
        &operations,
        manager,
        "dev.bragefuglseth.Keypunch",
        "flathub",
        "stable",
        .system,
    );
    defer if (replacement) |*value| value.deinit(context.allocator);
    try std.testing.expect(replacement != null);
    try std.testing.expectEqualStrings("no.bragefuglseth.Keypunch", replacement.?.id);
    try std.testing.expectEqualStrings("stable", replacement.?.branch);
}

test "Flatpak install EOL detection warns and proceeds for eol-only refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operations = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operations.deinit();

    var manager: EolInstallTestManager = .{
        .allocator = arena.allocator(),
        .remote_ref = makeEolRemoteRef("No longer maintained", null),
    };
    _ = &manager;

    const replacement = try resolveFlatpakEolInstallTarget(
        &context,
        &operations,
        manager,
        "org.example.Dead",
        "flathub",
        "stable",
        .system,
    );
    try std.testing.expect(replacement == null);
}

test "Flatpak install EOL detection treats remote fetch errors as advisory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operations = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operations.deinit();

    var manager: EolInstallTestManager = .{
        .allocator = arena.allocator(),
        .fetch_error = true,
    };
    _ = &manager;

    const replacement = try resolveFlatpakEolInstallTarget(
        &context,
        &operations,
        manager,
        "org.example.App",
        "flathub",
        "stable",
        .system,
    );
    try std.testing.expect(replacement == null);
}

test "Flatpak install EOL detection accepts full-ref replacement markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operations = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operations.deinit();

    var manager: EolInstallTestManager = .{
        .allocator = arena.allocator(),
        .remote_ref = makeEolRemoteRef(null, "app/no.bragefuglseth.Keypunch/x86_64/beta"),
    };
    _ = &manager;

    var replacement = try resolveFlatpakEolInstallTarget(
        &context,
        &operations,
        manager,
        "dev.bragefuglseth.Keypunch",
        "flathub",
        "stable",
        .system,
    );
    defer if (replacement) |*value| value.deinit(context.allocator);
    try std.testing.expect(replacement != null);
    try std.testing.expectEqualStrings("no.bragefuglseth.Keypunch", replacement.?.id);
    try std.testing.expectEqualStrings("beta", replacement.?.branch);
}

test "appimage install relaunch forwards positionals and install-path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const plain_outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "install", "appimage", "/tmp/demo.AppImage",
    });
    try std.testing.expect(plain_outcome == .dispatch);
    const plain_args = try appimageInstallArgs(std.testing.allocator, &plain_outcome.dispatch);
    defer std.testing.allocator.free(plain_args);
    const expected_plain = [_][]const u8{ "install", "appimage", "/tmp/demo.AppImage" };
    try std.testing.expectEqualSlices([]const u8, &expected_plain, plain_args);

    const full_outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "install", "appimage", "--no-confirm", "--install-path", "/opt/appimages", "/tmp/demo.AppImage",
    });
    try std.testing.expect(full_outcome == .dispatch);
    const full_args = try appimageInstallArgs(std.testing.allocator, &full_outcome.dispatch);
    defer std.testing.allocator.free(full_args);
    const expected_full = [_][]const u8{
        "install", "appimage", "--no-confirm", "--install-path", "/opt/appimages", "/tmp/demo.AppImage",
    };
    try std.testing.expectEqualSlices([]const u8, &expected_full, full_args);
}

test "install preserves actionable lock errors once in terminal and UI output" {
    const Failure = struct {
        pub fn run(_: @This(), context: *runtime.RuntimeContext, operations: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
            var operation = operations.begin(.{ .backend = .alpm, .kind = .install, .subject = "demo" });
            defer operation.finish(.failed);
            const message = try Zigalpm.user_errors.databaseLocked(context.allocator, "/custom/package database/");
            defer context.allocator.free(message);
            operation.reportError(error.AlpmOperationFailed, message, "alpm", null, false);
            return error.TransInitFailed;
        }
    };
    for ([_]bool{ false, true }) |ui_mode| {
        var tc: test_support.TestContext = .{};
        tc.init();
        defer tc.deinit();
        const alloc = tc.arena.allocator();
        const manifest = try spec.Manifest.load(alloc);
        const args: []const []const u8 = if (ui_mode)
            &.{ "install", "standard", "demo", "--ui-mode" }
        else
            &.{ "install", "standard", "demo" };
        const outcome = try parser.parse(alloc, &manifest, args);
        try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &outcome.dispatch, Failure{}));
        var decoded_output: std.Io.Writer.Allocating = .init(alloc);
        defer decoded_output.deinit();
        var error_frames: usize = 0;
        if (ui_mode) {
            var frames = std.mem.splitSequence(u8, tc.stdout.written(), "[JSON]");
            _ = frames.next();
            while (frames.next()) |frame| {
                const end = std.mem.indexOf(u8, frame, "[/JSON]") orelse return error.InvalidFrame;
                const encoded = frame[0..end];
                const bytes = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
                try std.base64.standard.Decoder.decode(bytes, encoded);
                if (std.mem.indexOf(u8, bytes, "\"$kind\":\"alpm.error\"") != null) error_frames += 1;
                try decoded_output.writer.writeAll(bytes);
            }
            try std.testing.expectEqual(@as(usize, 1), error_frames);
        } else try decoded_output.writer.writeAll(tc.stdout.written());
        const rendered = decoded_output.written();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "because the package database is locked"));
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Lock file: /custom/package database/db.lck") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "sudo rm -- '/custom/package database/db.lck'") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "If no package manager is running") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "TransInitFailed") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "unexpected error") == null);
    }
}
