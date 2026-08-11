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
        return try reportValidationFailure(context, invocation, "No packages specified.");

    if (!invocation.globals.ui_mode and needsElevation(invocation)) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate remove: {t}\n", .{err});
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
        .failure_label = "Removal failed",
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
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{ .root = true, .operation_context = operation_context });
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

    const target = resolveAppImage(
        context.allocator,
        context.io,
        invocation.positionals[0],
        search_paths,
    ) catch |err| switch (err) {
        RemoveError.AppImageNotFound => {
            const app_images = try manager.getAppImagesFromLocalDb();
            defer manager.freeAppImages(app_images);
            const app_name = try resolveAppImageDbName(app_images, invocation.positionals[0]);
            try manager.removeAppImageFromLocalDb(app_name);
            return;
        },
        else => return err,
    };
    defer context.allocator.free(target);

    if (!try manager.removeAppImage(target, optionEnabled(invocation, "--remove-config")))
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

fn resolveAppImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    search_paths: []const []const u8,
) ![]const u8 {
    var match: ?[]const u8 = null;
    errdefer if (match) |path| allocator.free(path);
    for (search_paths) |directory| {
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".AppImage")) continue;
            if (!containsTextIgnoreCase(entry.name, query)) continue;
            if (match != null) return RemoveError.AmbiguousAppImage;
            match = try std.fs.path.join(allocator, &.{ directory, entry.name });
        }
    }
    return match orelse RemoveError.AppImageNotFound;
}

fn resolveAppImageDbName(
    app_images: []const Zigalpm.appimage.AppImage,
    query: []const u8,
) ![]const u8 {
    var match: ?[]const u8 = null;
    for (app_images) |app_image| {
        if (!containsTextIgnoreCase(app_image.name, query)) continue;
        if (match != null) return RemoveError.AmbiguousAppImage;
        match = app_image.name;
    }
    return match orelse RemoveError.AppImageNotFound;
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
        context.stderr.print("Unable to resolve configuration directory: {t}\n", .{err}) catch {};
        return;
    };
    for (package_names) |package_name| {
        const path = std.fs.path.join(context.allocator, &.{ config_home, package_name }) catch |err| {
            context.stderr.print("Unable to build configuration path for {s}: {t}\n", .{ package_name, err }) catch {};
            continue;
        };
        defer context.allocator.free(path);
        std.Io.Dir.cwd().deleteTree(context.io, path) catch |err| {
            if (err == error.FileNotFound) continue;
            context.stderr.print("Unable to remove configuration for {s}: {t}\n", .{ package_name, err }) catch {};
        };
    }
}

fn cleanupFlatpakConfig(context: *runtime.RuntimeContext, canonical_id: []const u8) void {
    const home = xdg.getEnv(context, "HOME") orelse {
        context.stderr.print("Unable to resolve the home directory for Flatpak configuration cleanup.\n", .{}) catch {};
        return;
    };
    const path = std.fs.path.join(context.allocator, &.{ home, ".var", "app", canonical_id }) catch |err| {
        context.stderr.print("Unable to build Flatpak configuration path for {s}: {t}\n", .{ canonical_id, err }) catch {};
        return;
    };
    defer context.allocator.free(path);
    std.Io.Dir.cwd().deleteTree(context.io, path) catch |err| {
        if (err == error.FileNotFound) return;
        context.stderr.print("Unable to remove Flatpak configuration for {s}: {t}\n", .{ canonical_id, err }) catch {};
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
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path)) return "AppImage removal failed.";
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) return "Flatpak removal failed.";
    return "Package removal failed.";
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

    const resolved = try resolveAppImage(allocator, std.testing.io, "example", &.{ configured, fallback });
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(appimage, resolved);
    try std.testing.expectError(
        RemoveError.AppImageNotFound,
        resolveAppImage(allocator, std.testing.io, "missing", &.{ configured, fallback }),
    );

    const second = try std.fs.path.join(allocator, &.{ configured, "Another-Example.AppImage" });
    file = try std.Io.Dir.cwd().createFile(std.testing.io, second, .{});
    file.close(std.testing.io);
    try std.testing.expectError(
        RemoveError.AmbiguousAppImage,
        resolveAppImage(allocator, std.testing.io, "example", &.{ configured, fallback }),
    );
}

test "remove AppImage falls back to orphaned local database metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = absolute_buffer[0..absolute_length];
    const config_home = try std.fs.path.join(allocator, &.{ root, "config" });
    const bin_home = try std.fs.path.join(allocator, &.{ root, "bin" });
    const local_db_path = try std.fs.path.join(allocator, &.{ config_home, "shelly", "appimage-metadata-v2.db" });

    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("HOME", root);
    try environment.put("XDG_CONFIG_HOME", config_home);
    try environment.put("XDG_BIN_HOME", bin_home);
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

    const db_manager = Zigalpm.AppImageManager{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = bin_home,
        .local_db_path = local_db_path,
    };
    try db_manager.addAppImageToLocalDb(.{
        .name = "OrphanedEditor",
        .desktop_name = "Orphaned Editor",
        .path = "/missing/OrphanedEditor.AppImage",
    });

    const command_spec = @import("../cli/spec.zig");
    const manifest = try command_spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, &.{
        "remove", "appimage", "--no-confirm", "orphaned",
    });
    var operation_context = Zigalpm.OperationContext.init(allocator, std.testing.io);
    defer operation_context.deinit();

    try runAppImage(&context, &operation_context, &outcome.dispatch);

    const remaining = try db_manager.getAppImagesFromLocalDb();
    defer db_manager.freeAppImages(remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
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
