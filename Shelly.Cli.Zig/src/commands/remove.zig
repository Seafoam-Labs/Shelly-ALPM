const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const xdg = @import("../runtime/xdg.zig");
const aur_url = @import("../config/aur_url.zig");

const standard_command_path = "shelly remove standard";
const appimage_command_path = "shelly remove appimage";
const aur_command_path = "shelly remove aur";
const flatpak_command_path = "shelly remove flatpak";

const RemoveError = error{
    AmbiguousAppImage,
    AppImageNotFound,
    BackendFailed,
    BackendNotImplemented,
    FlatpakNotFound,
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
        if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
            return runFlatpak(context, operation_context, invocation);
        return RemoveError.BackendNotImplemented;
    }
};

const Partition = struct {
    alpm: []const []const u8,
    local: []const []const u8,

    fn deinit(self: *Partition, allocator: std.mem.Allocator) void {
        allocator.free(self.alpm);
        allocator.free(self.local);
        self.* = undefined;
    }
};

const DependencyRemoval = struct {
    flags: Zigalpm.alpm.TransFlag,
    remove_optional_dependencies: bool,
    keep_optional_dependencies: bool,
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isRemovePath(invocation.command.path)) return null;
    if (invocation.positionals.len == 0)
        return try reportValidationFailure(context, invocation, "Specify at least one package name. See the command help for usage.");

    if (!invocation.globals.ui_mode and needsElevation(invocation)) {
        const carries_aur = std.mem.eql(u8, invocation.command.path, aur_command_path);
        const elevated_arguments = if (carries_aur)
            try aur_url.argumentsWithEffectiveBase(context, invocation)
        else
            invocation.arguments;
        defer if (carries_aur) context.allocator.free(elevated_arguments);
        const elevated_exit = elevation.relaunchIfNeeded(context, elevated_arguments) catch |err| {
            try context.stderr.print("Could not obtain administrator privileges for package removal. {0s}\n\nTechnical details: {1s}\n", .{ @import("diagnostics").cause(err), @errorName(err) });
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
    const opening = try openingMessage(context.allocator, invocation);
    defer context.allocator.free(opening);
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner, opening)
    else
        executeStandard(context, invocation, runner, opening);
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
        .failure_label = "Could not remove the selected packages.",
    }, runner);
}

fn runStandard(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var local_manager = Zigalpm.LocalManager.init(context.allocator, context.io, .{});
    defer local_manager.deinit();
    local_manager.setOperationContext(operation_context);
    defer local_manager.setOperationContext(null);

    const local_only = optionEnabled(invocation, "--local");
    var local_names: std.ArrayList([]const u8) = .empty;
    defer local_names.deinit(context.allocator);
    var installed: ?[]Zigalpm.local.Package = null;
    defer if (installed) |packages| Zigalpm.local.Package.deinitSlice(context.allocator, packages);
    if (!local_only) {
        installed = try local_manager.getInstalledBinaryPackages();
        for (installed.?) |package| try local_names.append(context.allocator, package.name);
    }

    var partition = try partitionTargets(
        context.allocator,
        invocation.positionals,
        local_names.items,
        local_only,
    );
    defer partition.deinit(context.allocator);

    if (partition.alpm.len > 0) {
        const dependency_removal = dependencyRemoval(invocation, true, true);
        const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, .{ .use_root = true, .operation_context = operation_context });
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);
        const names = try sentinelStrings(context.allocator, partition.alpm);
        defer freeSentinelStrings(context.allocator, names);
        try manager.remove_packages(
            names,
            dependency_removal.flags,
            dependency_removal.keep_optional_dependencies,
        );
    }
    if (partition.local.len > 0 and !try local_manager.removeBinaryPackages(partition.local))
        return RemoveError.BackendFailed;

    if (optionEnabled(invocation, "--remove-config"))
        cleanupStandardConfig(context, invocation.positionals);
}

fn runAur(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const dependency_removal = dependencyRemoval(invocation, false, false);
    const aur_base = try aur_url.resolveFor(context, invocation);
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .aur_git_base_url = aur_base,
        .root = true,
        .operation_context = operation_context,
    });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);
    try manager.removePackages(
        invocation.positionals,
        dependency_removal.flags,
        dependency_removal.remove_optional_dependencies,
    );
}

fn runAppImage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (elevation.isRoot()) {
        const args = try appimageRemoveArgs(context.allocator, invocation);
        defer context.allocator.free(args);
        if (try elevation.runAsInvokingUser(context, args)) |exit_code| {
            if (exit_code != 0) return RemoveError.BackendFailed;
            return;
        }
        // A direct root invocation has no user to re-launch as. Continue
        // with root's own user-scoped AppImage store in that case.
    }

    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const fallback_directory = try xdg.binHome(context);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse fallback_directory;
    const search_paths: []const []const u8 = if (std.mem.eql(u8, install_directory, fallback_directory))
        &.{install_directory}
    else
        &.{ install_directory, fallback_directory };
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    defer context.allocator.free(local_db_path);
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

    const app_images = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(app_images);
    const target = try resolveAppImage(
        context.allocator,
        context.io,
        invocation.positionals[0],
        search_paths,
        app_images,
    );
    defer target.deinit(context.allocator);

    if (!try manager.removeAppImageByName(target.name, target.path, optionEnabled(invocation, "--remove-config")))
        return RemoveError.BackendFailed;
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    var application = (try manager.find_installed_flatpak(invocation.positionals[0])) orelse
        return RemoveError.FlatpakNotFound;
    defer application.deinit(context.allocator);
    if (!try manager.uninstall_flatpak(
        application.id,
        application.scope,
        optionEnabled(invocation, "--remove-unused"),
    )) return RemoveError.BackendFailed;
    if (optionEnabled(invocation, "--remove-config"))
        cleanupFlatpakConfig(context, application.id);
}

fn partitionTargets(
    allocator: std.mem.Allocator,
    targets: []const []const u8,
    installed_local_names: []const []const u8,
    local_only: bool,
) !Partition {
    var alpm: std.ArrayList([]const u8) = .empty;
    defer alpm.deinit(allocator);
    var local: std.ArrayList([]const u8) = .empty;
    defer local.deinit(allocator);
    for (targets) |target| {
        if (local_only or containsIgnoreCase(installed_local_names, target))
            try local.append(allocator, target)
        else
            try alpm.append(allocator, target);
    }
    return .{
        .alpm = try alpm.toOwnedSlice(allocator),
        .local = try local.toOwnedSlice(allocator),
    };
}

fn containsIgnoreCase(values: []const []const u8, target: []const u8) bool {
    for (values) |value| {
        if (std.ascii.eqlIgnoreCase(value, target)) return true;
    }
    return false;
}

fn removalFlags(cascade: bool, ripple: bool, force: bool) Zigalpm.alpm.TransFlag {
    if (force) return .{ .nodeps = true, .nodepversion = true };
    if (cascade) return .{ .nosave = true, .recurse = true };
    if (ripple) return .{ .cascade = true };
    return .{};
}

fn dependencyRemoval(
    invocation: *const parser.Invocation,
    cascade_by_default: bool,
    allow_force: bool,
) DependencyRemoval {
    const remove_optional_dependencies = optionEnabled(invocation, "--opt-deps");
    const cascade = !optionEnabled(invocation, "--no-cascade") and
        (cascade_by_default or optionEnabled(invocation, "--cascade"));
    return .{
        .flags = removalFlags(
            cascade,
            optionEnabled(invocation, "--ripple"),
            allow_force and optionEnabled(invocation, "--force"),
        ),
        .remove_optional_dependencies = remove_optional_dependencies,
        .keep_optional_dependencies = !remove_optional_dependencies,
    };
}

const AppImageRemovalTarget = struct {
    name: []const u8,
    path: []const u8,
    from_metadata: bool,

    fn deinit(self: AppImageRemovalTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

// Resolve parent-directory aliases without following the AppImage itself: removing
// an installed symlink must unlink that entry, not delete its target.
fn appImageRemovalPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const parent = std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", allocator) catch |err| switch (err) {
        error.FileNotFound => return std.fs.path.resolve(allocator, &.{path}),
        else => return err,
    };
    defer allocator.free(parent);
    return std.fs.path.join(allocator, &.{ parent, std.fs.path.basename(path) });
}

fn resolveAppImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    search_paths: []const []const u8,
    app_images: []const Zigalpm.appimage.AppImage,
) !AppImageRemovalTarget {
    var candidates: std.ArrayList(AppImageRemovalTarget) = .empty;
    defer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    // Keep metadata identities, including stale entries, before looking at files.
    // Old databases may contain repeated copies of the same installation.
    for (app_images) |app| {
        const fallback = try std.fmt.allocPrint(allocator, "{s}.AppImage", .{app.name});
        defer allocator.free(fallback);
        const raw_path = if (app.path.len > 0)
            try allocator.dupe(u8, app.path)
        else
            try std.fs.path.join(allocator, &.{ search_paths[0], fallback });
        defer allocator.free(raw_path);
        const path = try appImageRemovalPath(allocator, io, raw_path);
        errdefer allocator.free(path);
        const duplicate = for (candidates.items) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, app.name) and std.mem.eql(u8, candidate.path, path)) break true;
        } else false;
        if (duplicate) {
            allocator.free(path);
            continue;
        }
        const name = try allocator.dupe(u8, app.name);
        errdefer allocator.free(name);
        try candidates.append(allocator, .{ .name = name, .path = path, .from_metadata = true });
    }

    for (search_paths) |directory| {
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        const parent = try dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(parent);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".AppImage")) continue;
            const path = try std.fs.path.join(allocator, &.{ parent, entry.name });
            errdefer allocator.free(path);
            // This also deduplicates configured/fallback paths with trailing
            // slashes or symlinked directory aliases.
            const known = for (candidates.items) |candidate| {
                if (std.mem.eql(u8, candidate.path, path)) break true;
            } else false;
            if (known) {
                allocator.free(path);
                continue;
            }
            const name = try allocator.dupe(u8, std.fs.path.stem(entry.name));
            errdefer allocator.free(name);
            try candidates.append(allocator, .{ .name = name, .path = path, .from_metadata = false });
        }
    }

    var best: ?AppImageRemovalTarget = null;
    var best_rank: u8 = 0;
    var ambiguous = false;
    for (candidates.items) |candidate| {
        const name_exact = std.ascii.eqlIgnoreCase(candidate.name, query);
        const filename = std.fs.path.basename(candidate.path);
        const file_exact = std.ascii.eqlIgnoreCase(filename, query) or
            std.ascii.eqlIgnoreCase(std.fs.path.stem(filename), query);
        const rank: u8 = if (candidate.from_metadata and name_exact) 3 else if (name_exact or file_exact) 2 else if (containsTextIgnoreCase(candidate.name, query) or containsTextIgnoreCase(filename, query)) 1 else 0;
        if (rank == 0 or rank < best_rank) continue;
        if (rank == best_rank) {
            ambiguous = true;
        } else {
            best = candidate;
            best_rank = rank;
            ambiguous = false;
        }
    }
    if (ambiguous) return RemoveError.AmbiguousAppImage;
    const selected = best orelse return RemoveError.AppImageNotFound;
    // The backend removes metadata by name. Never drop another installation's
    // record when a legacy database reuses that name for different paths.
    if (selected.from_metadata) {
        for (candidates.items) |candidate| {
            if (candidate.from_metadata and std.ascii.eqlIgnoreCase(candidate.name, selected.name) and
                !std.mem.eql(u8, candidate.path, selected.path)) return RemoveError.AmbiguousAppImage;
        }
    }
    const name = try allocator.dupe(u8, selected.name);
    errdefer allocator.free(name);
    return .{
        .name = name,
        .path = try allocator.dupe(u8, selected.path),
        .from_metadata = selected.from_metadata,
    };
}

fn containsTextIgnoreCase(value: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > value.len) return false;
    var index: usize = 0;
    while (index + query.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + query.len], query)) return true;
    }
    return false;
}

fn cleanupStandardConfig(context: *runtime.RuntimeContext, package_names: []const []const u8) void {
    const config_home = xdg.configHome(context) catch |err| {
        context.stderr.print("Package removal completed, but the configuration directory could not be located. {0s} Configuration cleanup was not completed.\n\nTechnical details: {1s}\n", .{ @import("diagnostics").cause(err), @errorName(err) }) catch {};
        return;
    };
    for (package_names) |package_name| {
        const path = std.fs.path.join(context.allocator, &.{ config_home, package_name }) catch |err| {
            context.stderr.print("Package removal completed, but the configuration for {0f} could not be removed from the configured file. {1s}\n\nTechnical details: {2s}\n", .{ @import("diagnostics").safe(package_name), @import("diagnostics").cause(err), @errorName(err) }) catch {};
            continue;
        };
        defer context.allocator.free(path);
        std.Io.Dir.cwd().deleteTree(context.io, path) catch |err| {
            if (err == error.FileNotFound) continue;
            context.stderr.print("Package removal completed, but the configuration for {0f} could not be removed from {1f}. {2s}\n\nTechnical details: {3s}\n", .{ @import("diagnostics").safe(package_name), @import("diagnostics").safe(path), @import("diagnostics").cause(err), @errorName(err) }) catch {};
        };
    }
}

fn cleanupFlatpakConfig(context: *runtime.RuntimeContext, canonical_id: []const u8) void {
    const home = xdg.getEnv(context, "HOME") orelse {
        context.stderr.print("Package removal completed, but the user home directory could not be located for Flatpak configuration cleanup. Configuration cleanup was not completed.\n", .{}) catch {};
        return;
    };
    const path = std.fs.path.join(context.allocator, &.{ home, ".var", "app", canonical_id }) catch |err| {
        context.stderr.print("Flatpak removal completed, but the configuration for {0f} could not be removed from the configured file. {1s}\n\nTechnical details: {2s}\n", .{ @import("diagnostics").safe(canonical_id), @import("diagnostics").cause(err), @errorName(err) }) catch {};
        return;
    };
    defer context.allocator.free(path);
    std.Io.Dir.cwd().deleteTree(context.io, path) catch |err| {
        if (err == error.FileNotFound) return;
        context.stderr.print("Flatpak removal completed, but the configuration for {0f} could not be removed from {1f}. {2s}\n\nTechnical details: {3s}\n", .{ @import("diagnostics").safe(canonical_id), @import("diagnostics").safe(path), @import("diagnostics").cause(err), @errorName(err) }) catch {};
    };
}

fn reportValidationFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try output.writeFailure(context, message);
    try ui_operation.flush(context);
    return 1;
}

fn openingMessage(allocator: std.mem.Allocator, invocation: *const parser.Invocation) ![]const u8 {
    const names = try std.mem.join(allocator, ", ", invocation.positionals);
    defer allocator.free(names);
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return std.fmt.allocPrint(allocator, "Removing packages: {s}", .{names});
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return std.fmt.allocPrint(allocator, "Removing AUR packages: {s}", .{names});
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return std.fmt.allocPrint(allocator, "Removing AppImage: {s}", .{names});
    return std.fmt.allocPrint(allocator, "Removing Flatpak: {s}", .{names});
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return "AppImage removed successfully.";
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        return "Flatpak removed successfully.";
    return "Packages removed successfully.";
}

fn failureMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path)) return "Could not remove the selected AppImage.";
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) return "Could not remove the selected Flatpak from the selected installation.";
    return "Could not remove the selected packages.";
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

fn appimageRemoveArgs(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "remove", "appimage" });
    if (invocation.globals.no_confirm)
        try args.append(allocator, "--no-confirm");
    if (invocation.globals.json)
        try args.append(allocator, "--json");
    if (invocation.globals.ui_mode)
        try args.append(allocator, "--ui-mode");
    if (optionEnabled(invocation, "--remove-config"))
        try args.append(allocator, "--remove-config");
    for (invocation.positionals) |positional| try args.append(allocator, positional);
    return args.toOwnedSlice(allocator);
}

fn needsElevation(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path);
}

fn stringValue(config: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = config.values.get(key) orelse return null;
    return switch (value) {
        .string => |string| if (string.len > 0) string else null,
        else => null,
    };
}

fn isRemovePath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, appimage_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

test "recognizes every remove command path" {
    try std.testing.expect(isRemovePath(standard_command_path));
    try std.testing.expect(isRemovePath(appimage_command_path));
    try std.testing.expect(isRemovePath(aur_command_path));
    try std.testing.expect(isRemovePath(flatpak_command_path));
    try std.testing.expect(!isRemovePath("shelly install standard"));
}

test "maps dependency modifiers and force precedence" {
    const cascade = removalFlags(true, false, false);
    try std.testing.expect(cascade.nosave);
    try std.testing.expect(cascade.recurse);
    try std.testing.expect(!cascade.cascade);

    const ripple = removalFlags(false, true, false);
    try std.testing.expect(ripple.cascade);
    try std.testing.expect(!ripple.nosave);
    try std.testing.expect(!ripple.recurse);

    const force = removalFlags(true, true, true);
    try std.testing.expect(force.nodeps);
    try std.testing.expect(force.nodepversion);
    try std.testing.expect(!force.nosave);
    try std.testing.expect(!force.recurse);
    try std.testing.expect(!force.cascade);
}

test "maps optional dependency semantics for ALPM and AUR" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "standard", "--cascade", "--ripple", "--force", "--opt-deps", "demo",
    });
    var settings = dependencyRemoval(&outcome.dispatch, true, true);
    try std.testing.expect(settings.flags.nodeps);
    try std.testing.expect(settings.flags.nodepversion);
    try std.testing.expect(!settings.flags.cascade);
    try std.testing.expect(settings.remove_optional_dependencies);
    try std.testing.expect(!settings.keep_optional_dependencies);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "aur", "--ripple", "--opt-deps", "demo-git",
    });
    settings = dependencyRemoval(&outcome.dispatch, false, false);
    try std.testing.expect(settings.flags.cascade);
    try std.testing.expect(settings.remove_optional_dependencies);
    try std.testing.expect(!settings.keep_optional_dependencies);
}

test "standard removal cascades by default and supports an explicit opt out" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "standard", "demo",
    });
    var settings = dependencyRemoval(&outcome.dispatch, true, true);
    try std.testing.expect(settings.flags.nosave);
    try std.testing.expect(settings.flags.recurse);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "standard", "--no-cascade", "demo",
    });
    settings = dependencyRemoval(&outcome.dispatch, true, true);
    try std.testing.expect(!settings.flags.nosave);
    try std.testing.expect(!settings.flags.recurse);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "standard", "-c", "--no-cascade", "demo",
    });
    settings = dependencyRemoval(&outcome.dispatch, true, true);
    try std.testing.expect(!settings.flags.nosave);
    try std.testing.expect(!settings.flags.recurse);
}

test "partitions standard targets case-insensitively and honors local override" {
    var partition = try partitionTargets(
        std.testing.allocator,
        &.{ "repo-package", "LOCAL-TOOL", "another" },
        &.{ "local-tool", "another-local" },
        false,
    );
    defer partition.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices([]const u8, &.{ "repo-package", "another" }, partition.alpm);
    try std.testing.expectEqualSlices([]const u8, &.{"LOCAL-TOOL"}, partition.local);

    var local_only = try partitionTargets(
        std.testing.allocator,
        &.{ "repo-package", "LOCAL-TOOL" },
        &.{"local-tool"},
        true,
    );
    defer local_only.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), local_only.alpm.len);
    try std.testing.expectEqualSlices([]const u8, &.{ "repo-package", "LOCAL-TOOL" }, local_only.local);
}

test "routes every removal backend through shared output lifecycles" {
    const spec = @import("../cli/spec.zig");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Capture = struct {
        calls: usize = 0,

        pub fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            invocation: *const parser.Invocation,
        ) !void {
            self.calls += 1;
            if (std.mem.eql(u8, invocation.command.path, standard_command_path)) {
                try std.testing.expect(optionEnabled(invocation, "--cascade"));
                try std.testing.expect(optionEnabled(invocation, "--opt-deps"));
                try std.testing.expect(optionEnabled(invocation, "--remove-config"));
                return;
            }
            if (std.mem.eql(u8, invocation.command.path, aur_command_path)) {
                try std.testing.expect(optionEnabled(invocation, "--ripple"));
                try std.testing.expect(invocation.globals.ui_mode);
                return;
            }
            if (std.mem.eql(u8, invocation.command.path, appimage_command_path)) {
                try std.testing.expect(optionEnabled(invocation, "--remove-config"));
                return;
            }
            try std.testing.expectEqualStrings(flatpak_command_path, invocation.command.path);
            try std.testing.expect(optionEnabled(invocation, "--remove-unused"));
            try std.testing.expect(optionEnabled(invocation, "--remove-config"));
            try std.testing.expect(invocation.globals.ui_mode);
        }
    };
    var capture: Capture = .{};

    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "remove", "standard", "--no-confirm", "-c", "-o", "--remove-config", "demo",
    });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "demo") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "remove", "aur", "--ui-mode", "-i", "demo-git",
    });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "remove", "appimage", "--no-confirm", "--remove-config", "Editor",
    });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Editor") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "remove", "flatpak", "--ui-mode", "-r", "--remove-config", "Example",
    });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));
    try std.testing.expectEqual(@as(usize, 4), capture.calls);
}

test "remove confirmation accepts Enter but cancels on EOF and input failure" {
    const spec = @import("../cli/spec.zig");
    const shortcodes = @import("../cli/shortcodes.zig");
    const cases = [_]struct {
        input: ?[]const u8 = null,
        failing: bool = false,
        no_confirm: bool = false,
        accepted: bool = false,
    }{
        .{ .input = "\n", .accepted = true },
        .{ .input = "yes\n", .accepted = true },
        .{ .input = "invalid\ny\n", .accepted = true },
        .{ .input = "n\n" },
        .{ .input = "" },
        .{ .input = " " },
        .{ .input = "yes" },
        .{},
        .{ .failing = true },
        .{ .no_confirm = true, .accepted = true },
    };
    for ([_][]const []const u8{
        &.{ "-Rso", "demo" },
        &.{ "remove", "standard", "--opt-deps", "demo" },
    }) |arguments| {
        for (cases) |case| {
            var tc: test_support.TestContext = .{};
            tc.init();
            defer tc.deinit();
            var stdin = if (case.failing) std.Io.Reader.failing else std.Io.Reader.fixed(case.input orelse "");
            tc.context.stdin = if (case.input != null or case.failing) &stdin else null;
            const allocator = tc.arena.allocator();
            const manifest = try spec.Manifest.load(allocator);
            const args = if (case.no_confirm) try std.mem.concat(allocator, []const u8, &.{ arguments, &.{"-n"} }) else arguments;
            const translation = try shortcodes.translate(allocator, &manifest, args);
            const translated = switch (translation) {
                .unchanged, .translated => |value| value,
                else => return error.UnexpectedTranslation,
            };
            const outcome = try parser.parse(allocator, &manifest, translated);
            const Runner = struct {
                committed: bool = false,
                pub fn run(self: *@This(), _: *runtime.RuntimeContext, context: *Zigalpm.OperationContext, invocation: *const parser.Invocation) !void {
                    try std.testing.expectEqualStrings(standard_command_path, invocation.command.path);
                    try std.testing.expect(optionEnabled(invocation, "--opt-deps"));
                    var operation = context.begin(.{ .backend = .alpm, .kind = .remove, .subject = "demo" });
                    defer operation.finish(if (self.committed) .success else .cancelled);
                    const packages = [_]Zigalpm.OperationTransactionPackage{
                        .{ .name = "demo", .version = "1.0-1", .source = .local, .role = .requested, .installed_size = 1024 },
                        .{ .name = "demo-helper", .version = "2.0-1", .source = .local, .role = .optional_dependency, .installed_size = 2048 },
                    };
                    var answer = try operation.ask(.{
                        .kind = .confirm_transaction,
                        .prompt = "Proceed with package removal?",
                        .transaction_plan = .{ .action = .remove, .packages = &packages, .total_installed_size = 3072, .net_installed_size = -3072 },
                        .default_response = .accepted,
                    });
                    defer answer.deinit(context.allocator);
                    if (answer.response != .accepted) {
                        context.cancel();
                        return error.Cancelled;
                    }
                    self.committed = true;
                }
            };
            var runner = Runner{};
            _ = try executeWithRunner(&tc.context, &outcome.dispatch, &runner);
            try std.testing.expectEqual(case.accepted, runner.committed);
            const rendered = tc.stdout.writer.buffered();
            try std.testing.expect(std.mem.indexOf(u8, rendered, "Packages to remove:") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "demo-helper 2.0-1") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "Total removed size:") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "download:") == null);
            if (case.no_confirm) {
                try std.testing.expect(std.mem.indexOf(u8, rendered, "Proceed with package removal?") == null);
            } else if (tc.context.stdin != null) {
                try std.testing.expect(std.mem.indexOf(u8, rendered, "Proceed with package removal? (Y/n)") != null);
            }
        }
    }
}

test "remove backend failures return a nonzero status" {
    const spec = @import("../cli/spec.zig");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "remove", "standard", "--no-confirm", "demo",
    });
    const Failure = struct {
        pub fn run(_: @This(), _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
            return error.TestBackendFailure;
        }
    };

    try std.testing.expectEqual(
        @as(u8, 1),
        try executeWithRunner(&tc.context, &outcome.dispatch, Failure{}),
    );
}

test "rejects empty remove targets before backend execution" {
    const spec = @import("../cli/spec.zig");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "remove", "aur", "--ui-mode",
    });

    try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));
}

test "standard config cleanup removes existing targets and ignores missing ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var anchor: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-remove-config-test-{x}", .{@intFromPtr(&anchor)});
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const existing = try std.fs.path.join(allocator, &.{ root, "demo" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, existing);

    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("XDG_CONFIG_HOME", root);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };

    cleanupStandardConfig(&context, &.{ "demo", "not-installed" });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, existing, .{}));
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "resolves one AppImage across configured and fallback locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var anchor: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-remove-appimage-test-{x}", .{@intFromPtr(&anchor)});
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const configured = try std.fs.path.join(allocator, &.{ root, "configured" });
    const fallback = try std.fs.path.join(allocator, &.{ root, "fallback" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, configured);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fallback);
    const appimage = try std.fs.path.join(allocator, &.{ fallback, "Example-Editor.AppImage" });
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, appimage, .{});
    file.close(std.testing.io);

    const resolved = try resolveAppImage(allocator, std.testing.io, "example", &.{ configured, fallback }, &.{});
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings(appimage, resolved.path);
    try std.testing.expectError(
        RemoveError.AppImageNotFound,
        resolveAppImage(allocator, std.testing.io, "missing", &.{ configured, fallback }, &.{}),
    );

    const second = try std.fs.path.join(allocator, &.{ configured, "Another-Example.AppImage" });
    file = try std.Io.Dir.cwd().createFile(std.testing.io, second, .{});
    file.close(std.testing.io);
    try std.testing.expectError(
        RemoveError.AmbiguousAppImage,
        resolveAppImage(allocator, std.testing.io, "example", &.{ configured, fallback }, &.{}),
    );
}

test "AppImage removal preserves unrelated installations and cleans stale identities" {
    const Case = struct {
        query: []const u8 = "Editor",
        installed: bool = false,
        duplicate: bool = false,
        filename: []const u8 = "Editor.AppImage",
        other_name: []const u8 = "Editor-old",
        omit_path: bool = false,
        remove_config: bool = false,
        failure: ?anyerror = null,
    };
    for ([_]Case{
        .{}, // A missing exact selection must not remove Editor-old.
        .{ .duplicate = true },
        .{ .installed = true },
        .{ .installed = true, .filename = "renamed.AppImage" },
        .{ .filename = "renamed.AppImage" },
        .{ .installed = true, .omit_path = true },
        .{ .omit_path = true },
        .{ .query = "eDiToR" },
        .{ .query = "Editor.AppImage" },
        .{ .query = "Edit", .failure = RemoveError.AmbiguousAppImage },
        .{ .query = "missing", .failure = RemoveError.AppImageNotFound },
        .{ .other_name = "Editor", .failure = RemoveError.AmbiguousAppImage },
        .{ .other_name = "Editor", .query = "Editor.AppImage", .failure = RemoveError.AmbiguousAppImage },
        .{ .query = "Edit", .other_name = "Unrelated" }, // Unique partial queries remain supported.
        .{ .remove_config = true },
    }) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const io = std.testing.io;
        const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        var environment = std.process.Environ.Map.init(allocator);
        inline for (.{ "CONFIG", "DATA", "CACHE", "STATE", "BIN" }) |kind| {
            const directory = try std.fs.path.join(allocator, &.{ root, kind });
            try std.Io.Dir.cwd().createDirPath(io, directory);
            try environment.put("XDG_" ++ kind ++ "_HOME", directory);
        }
        const config_home = environment.get("XDG_CONFIG_HOME").?;
        const bin_home = environment.get("XDG_BIN_HOME").?;
        const data_home = environment.get("XDG_DATA_HOME").?;
        const config_directory = try std.fs.path.join(allocator, &.{ config_home, "shelly" });
        try std.Io.Dir.cwd().createDirPath(io, config_directory);
        const local_db_path = try std.fs.path.join(allocator, &.{ config_directory, "appimage-metadata-v2.db" });
        const target_path = try std.fs.path.join(allocator, &.{ bin_home, case.filename });
        const other_filename = try std.fmt.allocPrint(allocator, "{s}.AppImage", .{if (std.mem.eql(u8, case.other_name, "Editor")) "Editor-old" else case.other_name});
        const other_path = try std.fs.path.join(allocator, &.{ bin_home, other_filename });
        const records = [_]Zigalpm.appimage.AppImage{
            .{ .name = "Editor", .path = if (case.omit_path) "" else target_path },
            .{ .name = case.other_name, .path = other_path },
            .{ .name = "Editor", .path = if (case.omit_path) "" else target_path },
        };
        const original_db = try std.json.Stringify.valueAlloc(allocator, records[0..if (case.duplicate) @as(usize, 3) else 2], .{});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = local_db_path, .data = original_db });
        if (case.installed) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target_path, .data = "selected binary" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = other_path, .data = "unrelated binary" });

        const desktop_dir = try std.fs.path.join(allocator, &.{ data_home, "applications" });
        const icon_dir = try std.fs.path.join(allocator, &.{ data_home, "icons/hicolor/256x256/apps" });
        try std.Io.Dir.cwd().createDirPath(io, desktop_dir);
        try std.Io.Dir.cwd().createDirPath(io, icon_dir);
        const desktop = try std.fs.path.join(allocator, &.{ desktop_dir, "editor.desktop" });
        const other_desktop = try std.fs.path.join(allocator, &.{ desktop_dir, "editor-old.desktop" });
        const icon = try std.fs.path.join(allocator, &.{ icon_dir, "editor.png" });
        const other_icon = try std.fs.path.join(allocator, &.{ icon_dir, "editor-old.png" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = desktop, .data = try std.fmt.allocPrint(allocator, "[Desktop Entry]\nName=Editor\nExec=\"{s}\"\n", .{target_path}) });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = other_desktop, .data = "[Desktop Entry]\nName=Other\nExec=other\n" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = icon, .data = "selected icon" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = other_icon, .data = "unrelated icon" });
        const app_config = try std.fs.path.join(allocator, &.{ config_home, "Editor" });
        try std.Io.Dir.cwd().createDirPath(io, app_config);

        const environ: std.process.Environ = .{ .block = try environment.createPosixBlock(allocator, .{}) };
        var stdout = std.Io.Writer.Allocating.init(allocator);
        var stderr = std.Io.Writer.Allocating.init(allocator);
        var context: runtime.RuntimeContext = .{
            .allocator = allocator,
            .io = io,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
            .environment = &environment,
            .environ = environ,
        };
        const manifest = try @import("../cli/spec.zig").Manifest.load(allocator);
        const arguments: []const []const u8 = if (case.remove_config)
            &.{ "remove", "appimage", "--no-confirm", "--remove-config", case.query }
        else
            &.{ "remove", "appimage", "--no-confirm", case.query };
        const outcome = try parser.parse(allocator, &manifest, arguments);
        var operation_context = Zigalpm.OperationContext.init(allocator, io);
        defer operation_context.deinit();
        if (case.failure) |err| {
            try std.testing.expectError(err, runAppImage(&context, &operation_context, &outcome.dispatch));
            try std.testing.expectEqualStrings(original_db, try std.Io.Dir.cwd().readFileAlloc(io, local_db_path, allocator, .unlimited));
            try std.Io.Dir.cwd().access(io, desktop, .{});
            try std.Io.Dir.cwd().access(io, icon, .{});
            if (case.installed) try std.Io.Dir.cwd().access(io, target_path, .{});
        } else {
            try runAppImage(&context, &operation_context, &outcome.dispatch);
            const db_manager = Zigalpm.AppImageManager{
                .allocator = allocator,
                .io = io,
                .environ = environ,
                .install_directory = bin_home,
                .local_db_path = local_db_path,
            };
            const remaining = try db_manager.getAppImagesFromLocalDb();
            defer db_manager.freeAppImages(remaining);
            try std.testing.expectEqual(@as(usize, 1), remaining.len);
            try std.testing.expectEqualStrings(case.other_name, remaining[0].name);
            for ([_][]const u8{ target_path, desktop, icon }) |path| {
                try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
            }
        }
        try std.testing.expectEqualStrings("unrelated binary", try std.Io.Dir.cwd().readFileAlloc(io, other_path, allocator, .unlimited));
        try std.Io.Dir.cwd().access(io, other_desktop, .{});
        try std.Io.Dir.cwd().access(io, other_icon, .{});
        if (case.remove_config) {
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, app_config, .{}));
        } else {
            try std.Io.Dir.cwd().access(io, app_config, .{});
        }
    }
}

test "AppImage removal prefers exact files and deduplicates directory aliases" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try temporary.dir.createDirPath(io, "bin");
    try temporary.dir.symLink(io, "bin", "alias", .{ .is_directory = true });
    try temporary.dir.writeFile(io, .{ .sub_path = "bin/Editor.AppImage", .data = "selected" });
    try temporary.dir.writeFile(io, .{ .sub_path = "bin/Editor-old.AppImage", .data = "other" });
    const bin = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin);
    const slash = try std.fmt.allocPrint(allocator, "{s}/", .{bin});
    defer allocator.free(slash);
    const alias = try std.fs.path.join(allocator, &.{ root, "alias" });
    defer allocator.free(alias);
    const expected = try std.fs.path.join(allocator, &.{ bin, "Editor.AppImage" });
    defer allocator.free(expected);
    for ([_][]const u8{ "Editor", "Editor.AppImage", "eDiToR" }) |query| {
        const target = try resolveAppImage(allocator, io, query, &.{ slash, alias, bin }, &.{});
        defer target.deinit(allocator);
        try std.testing.expectEqualStrings(expected, target.path);
    }
    try std.testing.expectError(RemoveError.AmbiguousAppImage, resolveAppImage(allocator, io, "Edit", &.{ bin, alias }, &.{}));
    try temporary.dir.createDirPath(io, "distinct");
    try temporary.dir.writeFile(io, .{ .sub_path = "distinct/Editor.AppImage", .data = "distinct" });
    const distinct = try std.fs.path.join(allocator, &.{ root, "distinct" });
    defer allocator.free(distinct);
    try std.testing.expectError(RemoveError.AmbiguousAppImage, resolveAppImage(allocator, io, "Editor", &.{ bin, distinct }, &.{}));

    // A binary symlink is the removal target, not the file it points to.
    try temporary.dir.symLink(io, "../distinct/Editor.AppImage", "bin/Linked.AppImage", .{});
    const linked = try resolveAppImage(allocator, io, "Linked", &.{bin}, &.{});
    defer linked.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(u8, linked.path, "/bin/Linked.AppImage"));
}

test "flatpak config cleanup uses the canonical application id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var anchor: u8 = 0;
    const home = try std.fmt.allocPrint(allocator, "/tmp/shelly-remove-flatpak-test-{x}", .{@intFromPtr(&anchor)});
    std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
    const canonical = try std.fs.path.join(allocator, &.{ home, ".var", "app", "org.example.Canonical" });
    const friendly = try std.fs.path.join(allocator, &.{ home, ".var", "app", "Friendly Name" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, canonical);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, friendly);
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("HOME", home);
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = allocator,
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };

    cleanupFlatpakConfig(&context, "org.example.Canonical");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, canonical, .{}));
    try std.Io.Dir.cwd().access(std.testing.io, friendly, .{});
}

test "appimage remove relaunch forwards positionals and remove-config" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const plain_outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "appimage", "Editor",
    });
    try std.testing.expect(plain_outcome == .dispatch);
    const plain_args = try appimageRemoveArgs(std.testing.allocator, &plain_outcome.dispatch);
    defer std.testing.allocator.free(plain_args);
    const expected_plain = [_][]const u8{ "remove", "appimage", "Editor" };
    try std.testing.expectEqualSlices([]const u8, &expected_plain, plain_args);

    const full_outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "remove", "appimage", "--no-confirm", "--remove-config", "Editor",
    });
    try std.testing.expect(full_outcome == .dispatch);
    const full_args = try appimageRemoveArgs(std.testing.allocator, &full_outcome.dispatch);
    defer std.testing.allocator.free(full_args);
    const expected_full = [_][]const u8{ "remove", "appimage", "--no-confirm", "--remove-config", "Editor" };
    try std.testing.expectEqualSlices([]const u8, &expected_full, full_args);
}
