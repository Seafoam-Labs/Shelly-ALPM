const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");

const standard_command_path = "shelly sync standard";
const appimage_command_path = "shelly sync appimage";
const flatpak_command_path = "shelly sync flatpak";

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) anyerror!void,
};

const StandardRunnerAdapter = struct {
    runner: Runner,
    invocation: *const parser.Invocation,

    fn call(
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        const self: *StandardRunnerAdapter = @ptrCast(@alignCast(data.?));
        try self.runner.call(self.runner.data, context, operation_context, self.invocation);
    }
};

const real_standard_runner: Runner = .{ .call = runRealStandardSync };
const real_appimage_runner: Runner = .{ .call = runRealAppImageSync };
const real_flatpak_runner: Runner = .{ .call = runRealFlatpakSync };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    const is_standard = std.mem.eql(u8, invocation.command.path, standard_command_path);
    const is_appimage = std.mem.eql(u8, invocation.command.path, appimage_command_path);
    const is_flatpak = std.mem.eql(u8, invocation.command.path, flatpak_command_path);
    if (!is_standard and !is_appimage and !is_flatpak) return null;

    if (is_flatpak) {
        if (flatpakRemoteValidationFailure(invocation)) |message|
            return try reportValidationFailure(context, invocation, message);
    }

    const system_remote_mutation = is_flatpak and isFlatpakRemoteMutation(invocation) and
        booleanOption(invocation, "--system", true);
    if ((is_standard or system_remote_mutation) and !invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate sync: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(
        context,
        invocation,
        if (is_standard)
            real_standard_runner
        else if (is_appimage)
            real_appimage_runner
        else
            real_flatpak_runner,
    );
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner)
    else
        executeStandard(context, invocation, runner);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    var adapter: StandardRunnerAdapter = .{ .runner = runner, .invocation = invocation };
    const succeeded = try standard_single_pane.output(
        context,
        openingMessage(invocation),
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = StandardRunnerAdapter.call },
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();
    if (invocation.globals.no_confirm) {
        operation_context.setQuestionHandler(.{ .function = ui_operation.acceptQuestionDefaults });
        defer operation_context.setQuestionHandler(null);
    }
    var reporter: ui_operation.Reporter = .{ .context = context };
    const event_subscription = try operation_context.subscribe(.{
        .function = ui_operation.Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(event_subscription);

    try output.writeAlpmInfoFrame(context, "TransactionStart", openingMessage(invocation));
    try ui_operation.flush(context);

    runner.call(runner.data, context, &operation_context, invocation) catch |err| {
        if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
            try output.writeErrorFrame(context, message);
            try output.writeAlpmInfoFrame(context, "TransactionFailed", "Sync failed.");
            try ui_operation.flush(context);
            return 1;
        }
        const message = try std.fmt.allocPrint(context.allocator, "Sync failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", "Sync failed.");
        try ui_operation.flush(context);
        return 1;
    };

    try output.writeAlpmInfoFrame(
        context,
        "TransactionDone",
        successMessage(invocation),
    );
    try ui_operation.flush(context);
    return if (reporter.failed()) 1 else 0;
}

fn runRealStandardSync(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        null,
        true,
        null,
    );
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    try manager.sync(optionEnabled(invocation, "--force"));
}

fn runRealAppImageSync(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const configure_updates = optionEnabled(invocation, "--configure-updates") or
        invocation.positionals.len == 3;
    if (optionEnabled(invocation, "--configure-updates") and invocation.positionals.len != 3)
        return error.AppImageUpdateConfigurationRequiresAppImageUrlAndType;
    if (invocation.positionals.len == 2)
        return error.AppImageUpdateConfigurationRequiresType;
    if (invocation.positionals.len > 3)
        return error.TooManyAppImageSyncArguments;
    if (optionEnabled(invocation, "--prerelease") and !configure_updates)
        return error.PrereleaseRequiresUpdateConfiguration;

    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    defer context.allocator.free(local_db_path);

    if (configure_updates) {
        const appimage_name = invocation.positionals[0];
        const update_url = invocation.positionals[1];
        const update_type = parseAppImageUpdateType(invocation.positionals[2]) orelse
            return error.InvalidAppImageUpdateType;
        if (update_url.len == 0 and update_type != .none)
            return error.AppImageUpdateUrlRequired;

        var update_manager = Zigalpm.appimage.UpdateManager{
            .allocator = context.allocator,
            .io = context.io,
            .environ = context.environ,
            .install_directory = install_directory,
            .local_db_path = local_db_path,
        };
        defer update_manager.deinit();
        try update_manager.setOperationContext(operation_context);
        defer update_manager.setOperationContext(null) catch {};
        if (!try update_manager.configure_updates(
            update_url,
            appimage_name,
            update_type,
            optionEnabled(invocation, "--prerelease"),
        )) return error.AppImageNotFound;

        const message = try std.fmt.allocPrint(
            context.allocator,
            "Successfully configured updates for {s}.",
            .{appimage_name},
        );
        defer context.allocator.free(message);
        emitAppImageInfo(operation_context, message);
        return;
    }

    std.Io.Dir.cwd().access(context.io, install_directory, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "{s} directory does not exist. No AppImages to sync.",
                .{install_directory},
            );
            defer context.allocator.free(message);
            emitAppImageInfo(operation_context, message);
            return;
        },
        else => return err,
    };

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

    const names = if (invocation.positionals.len == 0)
        try allAppImageNames(context.allocator, app_images)
    else
        try matchingAppImageName(context, operation_context, app_images, invocation.positionals[0]);
    defer context.allocator.free(names);
    if (invocation.positionals.len != 0 and names.len == 0) return;
    if (!try manager.syncAppImageMeta(names)) return error.AppImageMetadataSyncFailed;
}

fn runRealFlatpakSync(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (isFlatpakRemoteMutation(invocation))
        return runRealFlatpakRemoteMutation(context, operation_context, invocation);

    var manager = Zigalpm.flatpak.AppstreamManager.init(context.allocator, context.io);
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    try manager.updateAllAppstreams();
}

fn runRealFlatpakRemoteMutation(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const operation = invocation.positionals[1];
    const name = try context.allocator.dupeZ(u8, invocation.positionals[2]);
    defer context.allocator.free(name);
    const scope: Zigalpm.flatpak.Scope =
        if (booleanOption(invocation, "--system", true)) .system else .user;
    var manager = Zigalpm.flatpak.RemoteManager{
        .allocator = context.allocator,
        .io = context.io,
    };
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    if (std.mem.eql(u8, operation, "add")) {
        const url = try context.allocator.dupeZ(u8, optionValue(invocation, "--remote-url").?);
        defer context.allocator.free(url);
        if (!try manager.addRemote(
            name,
            url,
            scope,
            booleanOption(invocation, "--gpg-verify", true),
        )) return error.FlatpakRemoteAddFailed;
        return;
    }
    if (!try manager.removeRemote(name, scope)) return error.FlatpakRemoteRemoveFailed;
}

fn openingMessage(invocation: *const parser.Invocation) []const u8 {
    return if (isFlatpakRemoteOperation(invocation, "add"))
        "Adding Flatpak remote..."
    else if (isFlatpakRemoteOperation(invocation, "remove"))
        "Removing Flatpak remote..."
    else if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        "Synchronizing Flatpak AppStream metadata..."
    else if (std.mem.eql(u8, invocation.command.path, appimage_command_path) and
        (invocation.positionals.len == 3 or optionEnabled(invocation, "--configure-updates")))
        "Configuring AppImage update metadata..."
    else if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        "Synchronizing AppImage metadata..."
    else
        "Synchronizing package databases...";
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    return if (isFlatpakRemoteOperation(invocation, "add"))
        "Flatpak remote added successfully!"
    else if (isFlatpakRemoteOperation(invocation, "remove"))
        "Flatpak remote removed successfully!"
    else if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        "Flatpak AppStream metadata synchronized successfully!"
    else if (std.mem.eql(u8, invocation.command.path, appimage_command_path) and
        (invocation.positionals.len == 3 or optionEnabled(invocation, "--configure-updates")))
        "AppImage update configuration saved successfully!"
    else if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        "AppImage metadata synchronized successfully!"
    else
        "Package databases synchronized successfully!";
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

fn hasOption(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return true;
    }
    return false;
}

fn booleanOption(
    invocation: *const parser.Invocation,
    name: []const u8,
    default_value: bool,
) bool {
    const value = optionValue(invocation, name) orelse return default_value;
    return !std.ascii.eqlIgnoreCase(value, "false");
}

fn isFlatpakRemoteMutation(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, flatpak_command_path) and
        invocation.positionals.len > 0 and
        std.mem.eql(u8, invocation.positionals[0], "remote");
}

fn isFlatpakRemoteOperation(invocation: *const parser.Invocation, operation: []const u8) bool {
    return isFlatpakRemoteMutation(invocation) and invocation.positionals.len > 1 and
        std.mem.eql(u8, invocation.positionals[1], operation);
}

fn flatpakRemoteValidationFailure(invocation: *const parser.Invocation) ?[]const u8 {
    if (invocation.positionals.len == 0) {
        if (hasOption(invocation, "--remote-url") or
            hasOption(invocation, "--system") or
            hasOption(invocation, "--gpg-verify"))
            return "Flatpak remote options require `sync flatpak remote add|remove <name>`.";
        return null;
    }
    if (!isFlatpakRemoteMutation(invocation) or invocation.positionals.len != 3)
        return "Flatpak remote configuration requires `remote add|remove <name>`.";
    if (isFlatpakRemoteOperation(invocation, "add")) {
        const url = optionValue(invocation, "--remote-url") orelse
            return "Flatpak remote add requires --remote-url.";
        if (std.mem.trim(u8, url, " \t\r\n").len == 0)
            return "Flatpak remote add requires a non-empty --remote-url.";
        return null;
    }
    if (hasOption(invocation, "--remote-url") or hasOption(invocation, "--gpg-verify"))
        return "Flatpak remote remove cannot use --remote-url or --gpg-verify.";
    return null;
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

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn allAppImageNames(
    allocator: std.mem.Allocator,
    app_images: []const Zigalpm.appimage.AppImage,
) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, app_images.len);
    for (app_images, names) |app_image, *name| name.* = app_image.name;
    return names;
}

fn matchingAppImageName(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    app_images: []const Zigalpm.appimage.AppImage,
    query: []const u8,
) ![]const []const u8 {
    for (app_images) |app_image| {
        if (!containsTextIgnoreCase(app_image.name, query)) continue;
        const names = try context.allocator.alloc([]const u8, 1);
        names[0] = app_image.name;
        return names;
    }
    const message = try std.fmt.allocPrint(
        context.allocator,
        "No AppImage matching \"{s}\" found in database.",
        .{query},
    );
    defer context.allocator.free(message);
    emitAppImageInfo(operation_context, message);
    return context.allocator.alloc([]const u8, 0);
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

fn parseAppImageUpdateType(value: []const u8) ?Zigalpm.appimage.UpdateType {
    if (std.ascii.eqlIgnoreCase(value, "None")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "StaticUrl")) return .static_url;
    if (std.ascii.eqlIgnoreCase(value, "GitHub")) return .github;
    if (std.ascii.eqlIgnoreCase(value, "GitLab")) return .gitlab;
    if (std.ascii.eqlIgnoreCase(value, "Codeberg")) return .codeberg;
    if (std.ascii.eqlIgnoreCase(value, "Forgejo")) return .forgejo;
    return null;
}

fn emitAppImageInfo(operation_context: *Zigalpm.OperationContext, message: []const u8) void {
    var operation = operation_context.begin(.{
        .backend = .appimage,
        .kind = .sync,
    });
    defer operation.finish(.success);
    operation.status(.information, message, "appimage.metadata.info", null);
}

test "sync forwards force and applies no-confirm through the shared operation context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync",
        "--force",
        "--no-confirm",
    });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct { force: bool = false, no_confirm: bool = false };
    var capture: Capture = .{};
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                runtime_context: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                invocation: *const parser.Invocation,
            ) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.force = optionEnabled(invocation, "--force");
                var operation = operation_context.begin(.{ .backend = .alpm, .kind = .sync });
                defer operation.finish(.success);
                var response = try operation.ask(.{ .kind = .confirmation, .prompt = "Continue?" });
                defer response.deinit(runtime_context.allocator);
                observed.no_confirm = response.response == .accepted;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.force);
    try std.testing.expect(capture.no_confirm);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Synchronizing package databases...") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "Flatpak sync uses the AppStream path and standard non-UI lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "flatpak" });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct { called: bool = false, force: bool = true };
    var capture: Capture = .{};
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                invocation: *const parser.Invocation,
            ) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.called = true;
                observed.force = optionEnabled(invocation, "--force");
                var operation = operation_context.begin(.{ .backend = .flatpak, .kind = .update });
                defer operation.finish(.success);
                operation.status(.success, "Flatpak AppStream catalog updated", "flatpak.appstream.updated", null);
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.called);
    try std.testing.expect(!capture.force);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Synchronizing Flatpak AppStream metadata...") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Flatpak AppStream catalog updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "Flatpak remote sync parses add and remove scopes and defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync",
        "flatpak",
        "remote",
        "add",
        "flathub-user",
        "--remote-url",
        "https://dl.flathub.org/repo/flathub.flatpakrepo",
        "--system",
        "false",
        "--gpg-verify",
        "false",
    });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isFlatpakRemoteOperation(&outcome.dispatch, "add"));
    try std.testing.expect(flatpakRemoteValidationFailure(&outcome.dispatch) == null);
    try std.testing.expect(!booleanOption(&outcome.dispatch, "--system", true));
    try std.testing.expect(!booleanOption(&outcome.dispatch, "--gpg-verify", true));
    try std.testing.expectEqualStrings(
        "https://dl.flathub.org/repo/flathub.flatpakrepo",
        optionValue(&outcome.dispatch, "--remote-url").?,
    );

    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync", "flatpak", "remote", "remove", "flathub",
    });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isFlatpakRemoteOperation(&outcome.dispatch, "remove"));
    try std.testing.expect(flatpakRemoteValidationFailure(&outcome.dispatch) == null);
    try std.testing.expect(booleanOption(&outcome.dispatch, "--system", true));
}

test "Flatpak remote sync validates operation-specific options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync", "flatpak", "remote", "add", "flathub",
    });
    try std.testing.expectEqualStrings(
        "Flatpak remote add requires --remote-url.",
        flatpakRemoteValidationFailure(&outcome.dispatch).?,
    );

    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync", "flatpak", "remote", "remove", "flathub", "--gpg-verify", "false",
    });
    try std.testing.expectEqualStrings(
        "Flatpak remote remove cannot use --remote-url or --gpg-verify.",
        flatpakRemoteValidationFailure(&outcome.dispatch).?,
    );

    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync", "flatpak", "--system", "false",
    });
    try std.testing.expectEqualStrings(
        "Flatpak remote options require `sync flatpak remote add|remove <name>`.",
        flatpakRemoteValidationFailure(&outcome.dispatch).?,
    );
}

test "Flatpak remote sync uses the shared transaction lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync",
        "flatpak",
        "remote",
        "add",
        "flathub-user",
        "--remote-url",
        "https://example.invalid/flathub.flatpakrepo",
        "--system",
        "false",
    });
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct { called: bool = false };
    var capture: Capture = .{};
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                invocation: *const parser.Invocation,
            ) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.called = true;
                try std.testing.expect(isFlatpakRemoteOperation(invocation, "add"));
                var operation = operation_context.begin(.{
                    .backend = .flatpak,
                    .kind = .configure,
                    .subject = invocation.positionals[2],
                });
                defer operation.finish(.success);
                operation.status(.success, "Flatpak remote added", "flatpak.remote.added", null);
            }
        }.run,
    };
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.called);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Adding Flatpak remote") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Flatpak remote added") != null);
}

test "AppImage sync routes long and shortcode forms with an optional package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "appimage", "Editor" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings(appimage_command_path, outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("Editor", outcome.dispatch.positionals[0]);

    const translation = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{ "-Yi", "Editor" },
    );
    outcome = try parser.parse(arena.allocator(), &manifest, translation.arguments().?);
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings(appimage_command_path, outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("Editor", outcome.dispatch.positionals[0]);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct { package: ?[]const u8 = null };
    var capture: Capture = .{};
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                invocation: *const parser.Invocation,
            ) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.package = invocation.positionals[0];
                emitAppImageInfo(operation_context, "Selected AppImage metadata synchronized.");
            }
        }.run,
    };
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualStrings("Editor", capture.package.?);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Synchronizing AppImage metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Selected AppImage metadata synchronized") != null);
}

test "AppImage sync accepts the update URL overload and compatibility shortcode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const expected_arguments = &.{
        "sync", "appimage", "Editor", "owner/repository", "GitHub", "--prerelease",
    };
    var outcome = try parser.parse(arena.allocator(), &manifest, expected_arguments);
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(@as(usize, 3), outcome.dispatch.positionals.len);
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--prerelease"));
    try std.testing.expectEqual(Zigalpm.appimage.UpdateType.github, parseAppImageUpdateType(outcome.dispatch.positionals[2]).?);

    const compatibility = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{ "-CIp", "Editor", "owner/repository", "GitHub" },
    );
    outcome = try parser.parse(arena.allocator(), &manifest, compatibility.arguments().?);
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings(appimage_command_path, outcome.dispatch.command.path);
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--prerelease"));
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--configure-updates"));

    const canonical = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{ "-Yip", "Editor", "owner/repository", "GitHub" },
    );
    outcome = try parser.parse(arena.allocator(), &manifest, canonical.arguments().?);
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--prerelease"));
}

test "real AppImage runner persists update URL type and prerelease policy" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..path_length];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    const install_directory = try std.fs.path.join(allocator, &.{ home, ".local", "bin" });
    const local_db_path = try std.fs.path.join(allocator, &.{ root, "shelly", "appimage-metadata-v2.db" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, install_directory);

    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("HOME", home);
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
    var appimage_manager = Zigalpm.AppImageManager{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer appimage_manager.deinit();
    try appimage_manager.addAppImageToLocalDb(.{ .name = "Editor" });

    const manifest = try spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, &.{
        "sync", "appimage", "Editor", "owner/repository", "GitHub", "--prerelease",
    });
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&context, &outcome.dispatch, real_appimage_runner),
    );

    const app_images = try appimage_manager.getAppImagesFromLocalDb();
    defer appimage_manager.freeAppImages(app_images);
    try std.testing.expectEqual(@as(usize, 1), app_images.len);
    try std.testing.expectEqual(Zigalpm.appimage.UpdateType.github, app_images[0].update_type);
    try std.testing.expectEqualStrings("owner", app_images[0].repo_owner.?);
    try std.testing.expectEqualStrings("repository", app_images[0].repo_name.?);
    try std.testing.expect(app_images[0].allow_prerelease);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Successfully configured updates for Editor") != null);
}

test "real AppImage runner reports a missing install directory without failing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..path_length];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("HOME", home);
    try environment.put("XDG_CONFIG_HOME", root);

    const manifest = try spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, &.{ "sync", "appimage" });
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

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&context, &outcome.dispatch, real_appimage_runner),
    );
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "directory does not exist. No AppImages to sync") != null);
}

test "AppImage sync name matching is case insensitive and selects the first match" {
    const app_images = [_]Zigalpm.appimage.AppImage{
        .{ .name = "Editor-Nightly" },
        .{ .name = "Editor-Stable" },
    };
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
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();

    const selected = try matchingAppImageName(&context, &operation_context, &app_images, "EDITOR");
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("Editor-Nightly", selected[0]);
}

test "sync flushes its initial status before starting the backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{"sync"});
    try std.testing.expect(outcome == .dispatch);

    const TrackingWriter = struct {
        interface: std.Io.Writer = undefined,
        buffer: [4096]u8 = undefined,
        flush_count: usize = 0,

        fn init(self: *@This()) void {
            self.interface = .{
                .vtable = &.{ .drain = drain, .flush = flush },
                .buffer = &self.buffer,
            };
        }

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            writer.end = 0;
            return std.Io.Writer.countSplat(data, splat);
        }

        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer));
            self.flush_count += 1;
            writer.end = 0;
        }
    };
    var stdout: TrackingWriter = .{};
    stdout.init();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.interface,
        .stderr = &stderr.writer,
    };
    const Capture = struct { writer: *TrackingWriter, initial_status_was_flushed: bool = false };
    var capture: Capture = .{ .writer = &stdout };
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.initial_status_was_flushed = observed.writer.flush_count > 0;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.initial_status_was_flushed);
}

test "sync reports backend failures and returns a failure exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "standard" });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const runner: Runner = .{ .call = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
            return error.TestSyncFailure;
        }
    }.run };

    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "error: TestSyncFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction failed.") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "sync UI mode emits transaction frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "standard", "--ui-mode" });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const runner: Runner = .{ .call = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, operation_context: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
            var operation = operation_context.begin(.{
                .backend = .download,
                .kind = .download,
                .subject = "extra.db",
            });
            defer operation.finish(.success);
            operation.progress(.{ .bytes_completed = 50, .bytes_total = 100 });
        }
    }.run };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, stdout.writer.buffered(), "[JSON]"));
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}
