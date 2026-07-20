const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const table = @import("../output/table.zig");
const ui_operation = @import("../output/ui_operation.zig");
const list_updates = @import("list_updates.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const xdg = @import("../runtime/xdg.zig");
const spec = @import("../cli/spec.zig");

const standard_command_path = "shelly upgrade standard";
const all_command_path = "shelly upgrade all";
const appimage_command_path = "shelly upgrade appimage";
const aur_command_path = "shelly upgrade aur";
const flatpak_command_path = "shelly upgrade flatpak";

const UpgradeError = error{
    BackendFailed,
    OneOrMoreBackendsFailed,
};

const Backend = enum {
    standard,
    aur,
    flatpak,
    appimage,

    fn operationBackend(self: Backend) Zigalpm.OperationBackend {
        return switch (self) {
            .standard => .alpm,
            .aur => .aur,
            .flatpak => .flatpak,
            .appimage => .appimage,
        };
    }

    fn displayName(self: Backend) []const u8 {
        return switch (self) {
            .standard => "Standard",
            .aur => "AUR",
            .flatpak => "Flatpak",
            .appimage => "AppImage",
        };
    }
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        backend: Backend,
        invocation: *const parser.Invocation,
    ) anyerror!void,
};

const RunnerAdapter = struct {
    runner: Runner,
    invocation: *const parser.Invocation,

    fn call(
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        const self: *RunnerAdapter = @ptrCast(@alignCast(data.?));
        try runSelected(self.runner, context, operation_context, self.invocation);
    }
};

const real_runner: Runner = .{ .call = runRealUpgrade };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isUpgradePath(invocation.command.path)) return null;

    const running_as_root = elevation.isRoot();
    if (shouldPrepareAllPreview(invocation, running_as_root)) {
        const preview = prepareAllUpgradePreview(context, invocation) catch |err| {
            try context.stderr.print("Unable to prepare combined upgrade plan: {t}\n", .{err});
            return 1;
        };
        if (!preview.proceed or !preview.has_updates) return 0;
    }

    if (!invocation.globals.ui_mode and requiresElevation(invocation)) {
        if (shouldPrepareStandardPreview(invocation, running_as_root)) {
            const preview = prepareStandardUpgradePreview(context, invocation) catch |err| {
                try context.stderr.print("Unable to prepare upgrade plan: {t}\n", .{err});
                return 1;
            };
            if (!preview.proceed or !preview.has_updates) return 0;
        }
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate upgrade: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(context, invocation, real_runner);
}

const PreviewResult = struct {
    has_updates: bool,
    proceed: bool,
};

const PlanCollector = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        backend: Backend,
    ) anyerror!list_updates.Result,
};

const UpgradePlan = struct {
    results: std.ArrayList(list_updates.Result) = .empty,

    fn deinit(self: *UpgradePlan, allocator: std.mem.Allocator) void {
        for (self.results.items) |*result| result.deinit(allocator);
        self.results.deinit(allocator);
        self.* = undefined;
    }

    fn isEmpty(self: *const UpgradePlan) bool {
        for (self.results.items) |*result| {
            if (list_updates.resultCount(result) != 0) return false;
        }
        return true;
    }

    fn find(self: *const UpgradePlan, backend: list_updates.Backend) ?*const list_updates.Result {
        for (self.results.items) |*result| {
            if (std.meta.activeTag(result.*) == backend) return result;
        }
        return null;
    }
};

const real_plan_collector: PlanCollector = .{ .call = collectPlanUpdates };

fn collectPlanUpdates(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    backend: Backend,
) !list_updates.Result {
    return list_updates.collectUpdates(context, listUpdatesBackend(backend), false);
}

fn prepareAllUpgradePreview(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !PreviewResult {
    return prepareAllUpgradePreviewWithCollector(context, invocation, real_plan_collector);
}

fn prepareAllUpgradePreviewWithCollector(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    collector: PlanCollector,
) !PreviewResult {
    var plan = try buildAllUpgradePlan(context, invocation, collector);
    defer plan.deinit(context.allocator);

    if (plan.isEmpty()) {
        try context.stdout.writeAll("Everything is up to date.\n");
        try context.stdout.flush();
        return .{ .has_updates = false, .proceed = false };
    }

    try renderAllUpgradePlan(context, &plan);
    if (invocation.globals.no_confirm)
        return .{ .has_updates = true, .proceed = true };

    const proceed = try confirmPreparedUpgrade(context, "Proceed with all upgrades?");
    if (!proceed) {
        try context.stdout.writeAll("Upgrade cancelled.\n");
        try context.stdout.flush();
    }
    return .{ .has_updates = true, .proceed = proceed };
}

fn buildAllUpgradePlan(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    collector: PlanCollector,
) !UpgradePlan {
    var plan: UpgradePlan = .{};
    errdefer plan.deinit(context.allocator);

    try context.stdout.writeAll("Building upgrade plan...\n");
    try context.stdout.flush();
    for (all_backends) |backend| {
        if (!backendEnabled(invocation, backend)) continue;
        try context.stdout.print("{s}\n", .{collectingMessage(backend)});
        try context.stdout.flush();

        var result = collector.call(collector.data, context, backend) catch |err| {
            try context.stdout.print("Error collecting {s} upgrades: {t}\n", .{
                backend.displayName(),
                err,
            });
            try context.stdout.flush();
            continue;
        };
        const count = list_updates.resultCount(&result);
        if (count == 0) {
            try context.stdout.print("{s}\n", .{noUpdatesMessage(backend)});
            try context.stdout.flush();
        }
        plan.results.append(context.allocator, result) catch |err| {
            result.deinit(context.allocator);
            return err;
        };
    }
    return plan;
}

fn renderAllUpgradePlan(context: *runtime.RuntimeContext, plan: *const UpgradePlan) !void {
    try context.stdout.writeAll("The following upgrades are planned:\n\n");
    const size_display = try loadSizeDisplay(context);

    if (plan.find(.standard)) |result| {
        const updates = result.standard.items;
        if (updates.len != 0) try renderPlannedStandardUpdates(context, size_display, updates);
    }
    if (plan.find(.aur)) |result| {
        const updates = result.aur.items;
        if (updates.len != 0) {
            try context.stdout.print("AUR ({d}):\n", .{updates.len});
            for (updates) |update|
                try context.stdout.print("  {s}: {s} -> {s}\n", .{
                    update.name,
                    update.version,
                    update.new_version,
                });
            try context.stdout.writeByte('\n');
        }
    }
    if (plan.find(.flatpak)) |result| {
        const updates = result.flatpak.items;
        if (updates.len != 0) {
            const sorted = try context.allocator.dupe(list_updates.FlatpakUpdate, updates);
            defer context.allocator.free(sorted);
            std.mem.sort(list_updates.FlatpakUpdate, sorted, {}, struct {
                fn lessThan(_: void, lhs: list_updates.FlatpakUpdate, rhs: list_updates.FlatpakUpdate) bool {
                    return std.mem.lessThan(u8, lhs.id, rhs.id);
                }
            }.lessThan);
            try context.stdout.print("Flatpak ({d}):\n", .{sorted.len});
            for (sorted) |update|
                try context.stdout.print("  {s} ({s})\n", .{ update.name, update.id });
            try context.stdout.writeByte('\n');
        }
    }
    if (plan.find(.appimage)) |result| {
        const updates = result.appimage.items;
        if (updates.len != 0) {
            try context.stdout.print("AppImage ({d}):\n", .{updates.len});
            for (updates) |update|
                try context.stdout.print("  {s} -> {s}\n", .{ update.name, update.version });
            try context.stdout.writeByte('\n');
        }
    }
    try context.stdout.flush();
}

fn renderPlannedStandardUpdates(
    context: *runtime.RuntimeContext,
    size_display: SizeDisplay,
    updates: []const list_updates.StandardUpdate,
) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const rows = try allocator.alloc([]const []const u8, updates.len);
    var total_download: i128 = 0;
    var net_change: i128 = 0;
    for (updates, rows) |update, *row| {
        total_download += update.download_size;
        net_change += update.size_difference;
        const cells = try allocator.alloc([]const u8, 6);
        cells[0] = update.repository;
        cells[1] = update.name;
        cells[2] = update.current_version;
        cells[3] = update.new_version;
        cells[4] = try formatUpgradeSize(allocator, size_display, update.size_difference);
        cells[5] = try formatUpgradeSize(allocator, size_display, update.download_size);
        row.* = cells;
    }

    try context.stdout.print("Repository ({d}):\n", .{updates.len});
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Repository", "Package", "Old Version", "New Version", "Net Change", "Download Size" },
        rows,
        output.supportsAnsi(context),
    );
    const formatted_download = try formatUpgradeSize(allocator, size_display, total_download);
    const formatted_change = try formatUpgradeSize(allocator, size_display, net_change);
    try context.stdout.print(
        "\nTotal Download Size: {s}\nNet Upgrade Size: {s}\n\n",
        .{ formatted_download, formatted_change },
    );
}

fn listUpdatesBackend(backend: Backend) list_updates.Backend {
    return switch (backend) {
        .standard => .standard,
        .aur => .aur,
        .flatpak => .flatpak,
        .appimage => .appimage,
    };
}

fn collectingMessage(backend: Backend) []const u8 {
    return switch (backend) {
        .standard => "Collecting Standard Packages for upgrade.",
        .aur => "Collecting AUR Packages",
        .flatpak => "Collecting Flatpak Apps",
        .appimage => "Collecting AppImages",
    };
}

fn noUpdatesMessage(backend: Backend) []const u8 {
    return switch (backend) {
        .standard => "No standard packages to upgrade.",
        .aur => "No AUR packages to upgrade.",
        .flatpak => "No Flatpak apps to upgrade.",
        .appimage => "No AppImages to upgrade.",
    };
}

const SizeDisplay = enum {
    bytes,
    megabytes,
    gigabytes,
};

fn prepareStandardUpgradePreview(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !PreviewResult {
    try context.stdout.writeAll("Preparing standard upgrade plan...\n");
    try context.stdout.flush();

    const database_path = try xdg.shellyCache(context, &.{"db"});
    defer context.allocator.free(database_path);
    try std.Io.Dir.cwd().createDirPath(context.io, database_path);

    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        null,
        false,
        database_path,
    );
    defer manager.deinit();
    try manager.sync_for_update_check(false);

    const updates = try manager.get_updates_available();
    defer Zigalpm.alpm.OwnedPackageWithUpdate.deinitSlice(context.allocator, updates);
    if (updates.len == 0) {
        try context.stdout.writeAll("Standard Packages are up to date!\n");
        try context.stdout.flush();
        return .{ .has_updates = false, .proceed = false };
    }

    try renderStandardUpgradePreview(context, updates);
    if (invocation.globals.no_confirm) return .{ .has_updates = true, .proceed = true };

    const proceed = try confirmPreparedUpgrade(context, "Proceed with upgrade?");
    if (!proceed) {
        try context.stdout.writeAll("Upgrade cancelled.\n");
        try context.stdout.flush();
    }
    return .{ .has_updates = true, .proceed = proceed };
}

fn renderStandardUpgradePreview(
    context: *runtime.RuntimeContext,
    updates: []const Zigalpm.alpm.OwnedPackageWithUpdate,
) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const size_display = try loadSizeDisplay(context);
    const rows = try allocator.alloc([]const []const u8, updates.len);
    var total_download: i128 = 0;
    var net_change: i128 = 0;

    for (updates, rows) |update, *row| {
        const download_size: i128 = @max(0, @as(i128, update.new_package.download_size()));
        const size_change = @as(i128, update.new_package.install_size()) -
            @as(i128, update.old_package.install_size());
        total_download += download_size;
        net_change += size_change;

        const cells = try allocator.alloc([]const u8, 6);
        cells[0] = update.new_package.repository() orelse "unknown";
        cells[1] = update.new_package.name() orelse "unknown";
        cells[2] = update.old_package.version() orelse "unknown";
        cells[3] = update.new_package.version() orelse "unknown";
        cells[4] = try formatUpgradeSize(allocator, size_display, size_change);
        cells[5] = try formatUpgradeSize(allocator, size_display, download_size);
        row.* = cells;
    }

    try context.stdout.writeAll("The following upgrades are planned:\n\n");
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Repository", "Package", "Old Version", "New Version", "Net Change", "Download Size" },
        rows,
        output.supportsAnsi(context),
    );
    const formatted_download = try formatUpgradeSize(allocator, size_display, total_download);
    const formatted_change = try formatUpgradeSize(allocator, size_display, net_change);
    try context.stdout.print(
        "\nTotal Download Size: {s}\nNet Upgrade Size: {s}\n\n",
        .{ formatted_download, formatted_change },
    );
    try context.stdout.flush();
}

fn confirmPreparedUpgrade(context: *runtime.RuntimeContext, prompt: []const u8) !bool {
    const reader = context.stdin orelse return false;
    while (true) {
        try context.stdout.print("{s} (Y/n) ", .{prompt});
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse return false;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "y") or
            std.ascii.eqlIgnoreCase(answer, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(answer, "n") or
            std.ascii.eqlIgnoreCase(answer, "no")) return false;
        try context.stdout.writeAll("Please answer 'y' or 'n'.\n");
    }
}

fn loadSizeDisplay(context: *runtime.RuntimeContext) !SizeDisplay {
    const manager = config_manager.Manager.init(context);
    const configuration = manager.read() catch return .megabytes;
    const value = configuration.values.get("FileSizeDisplay") orelse return .megabytes;
    if (value != .string) return .megabytes;
    if (std.ascii.eqlIgnoreCase(value.string, "Bytes")) return .bytes;
    if (std.ascii.eqlIgnoreCase(value.string, "Gigabytes")) return .gigabytes;
    return .megabytes;
}

fn formatUpgradeSize(
    allocator: std.mem.Allocator,
    display: SizeDisplay,
    bytes: i128,
) ![]const u8 {
    return switch (display) {
        .bytes => std.fmt.allocPrint(allocator, "{d} B", .{bytes}),
        .megabytes => std.fmt.allocPrint(
            allocator,
            "{d:.2} MiB",
            .{@as(f64, @floatFromInt(bytes)) / 1048576.0},
        ),
        .gigabytes => std.fmt.allocPrint(
            allocator,
            "{d:.2} GiB",
            .{@as(f64, @floatFromInt(bytes)) / 1073741824.0},
        ),
    };
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
    var adapter: RunnerAdapter = .{ .runner = runner, .invocation = invocation };
    const succeeded = try standard_single_pane.output(
        context,
        openingMessage(invocation),
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = RunnerAdapter.call },
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    var question_responder: ui_operation.QuestionResponder = .{
        .context = context,
        .operation_context = &operation_context,
        .no_confirm = invocation.globals.no_confirm,
    };
    question_responder.attach();
    defer question_responder.detach();
    var reporter: ui_operation.Reporter = .{ .context = context };
    const event_subscription = try operation_context.subscribe(.{
        .function = ui_operation.Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(event_subscription);

    try output.writeAlpmInfoFrame(context, "TransactionStart", openingMessage(invocation));
    try ui_operation.flush(context);

    runSelected(runner, context, &operation_context, invocation) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Upgrade failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", failureMessage(invocation));
        try ui_operation.flush(context);
        return 1;
    };

    try output.writeAlpmInfoFrame(context, "TransactionDone", successMessage(invocation));
    try ui_operation.flush(context);
    return if (reporter.failed()) 1 else 0;
}

fn runSelected(
    runner: Runner,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (!upgradesAll(invocation)) {
        try runner.call(
            runner.data,
            context,
            operation_context,
            backendForPath(invocation.command.path) orelse unreachable,
            invocation,
        );
        return;
    }

    var failed = false;
    for (all_backends) |backend| {
        if (!backendEnabled(invocation, backend)) continue;
        runner.call(runner.data, context, operation_context, backend, invocation) catch |err| {
            failed = true;
            try reportBackendFailure(context, operation_context, backend, err);
        };
    }
    if (failed) return UpgradeError.OneOrMoreBackendsFailed;
}

const all_backends = [_]Backend{ .standard, .aur, .flatpak, .appimage };

fn runRealUpgrade(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    invocation: *const parser.Invocation,
) !void {
    return switch (backend) {
        .standard => runStandard(context, operation_context, invocation),
        .aur => runAur(context, operation_context, invocation),
        .flatpak => runFlatpakStep(context, operation_context, invocation),
        .appimage => runAppImage(context, operation_context),
    };
}

fn runStandard(
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

    try manager.sync(false);
    const updates = try manager.get_updates_available();
    defer Zigalpm.alpm.OwnedPackageWithUpdate.deinitSlice(context.allocator, updates);
    if (updates.len == 0) {
        emitStatus(operation_context, .standard, .success, "Standard Packages are up to date!");
        return;
    }

    try emitFormattedStatus(
        context,
        operation_context,
        .standard,
        .information,
        "{d} standard packages need updates:",
        .{updates.len},
    );
    for (updates) |update| {
        try emitFormattedStatus(
            context,
            operation_context,
            .standard,
            .information,
            "  {s}/{s}: {s} -> {s}",
            .{
                update.new_package.repository() orelse "unknown",
                update.new_package.name() orelse "unknown",
                update.old_package.version() orelse "unknown",
                update.new_package.version() orelse "unknown",
            },
        );
    }

    var restart_report = try manager.sync_system_update(.{});
    defer restart_report.deinit();
    if (invocation.globals.ui_mode and restart_report.needs_reboot)
        emitStatus(operation_context, .standard, .warning, "[RESTART_REQUIRED]reboot");
    for (restart_report.failures) |failure| {
        try emitFormattedStatus(
            context,
            operation_context,
            .standard,
            .warning,
            "[RESTART_FAILED]service:{s}|{s}",
            .{ failure.service, failure.message },
        );
    }
}

fn runAur(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    // The Zig CLI always renders non-UI operations through the shared single
    // pane. Accepting --singlepane therefore preserves the C# modifier while
    // selecting the same native output path as the default.
    _ = optionEnabled(invocation, "--singlepane");

    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .root = true,
        .no_check = !optionEnabled(invocation, "--check"),
    });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    const updates = try manager.getPackagesNeedingUpdate(true);
    defer Zigalpm.aur.models.Update.deinitSlice(context.allocator, updates);
    if (updates.len == 0) {
        emitStatus(operation_context, .aur, .success, "All AUR packages are up to date.");
        return;
    }

    try emitFormattedStatus(
        context,
        operation_context,
        .aur,
        .information,
        "{d} AUR packages need updates:",
        .{updates.len},
    );
    const package_names = try context.allocator.alloc([]const u8, updates.len);
    defer context.allocator.free(package_names);
    for (updates, package_names) |update, *name| {
        name.* = update.name;
        try emitFormattedStatus(
            context,
            operation_context,
            .aur,
            .information,
            "  {s}: {s} -> {s}",
            .{ update.name, update.version, update.new_version },
        );
    }
    try manager.updatePackages(package_names);
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    if (!try manager.upgrade_flatpaks()) return UpgradeError.BackendFailed;
}

fn runFlatpakStep(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (upgradesAll(invocation) and
        !invocation.globals.ui_mode)
    {
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(context.allocator);
        try arguments.appendSlice(context.allocator, &.{ "upgrade", "flatpak" });
        if (invocation.globals.no_confirm)
            try arguments.append(context.allocator, "--no-confirm");
        if (invocation.globals.json)
            try arguments.append(context.allocator, "--json");
        if (try elevation.runAsInvokingUser(context, arguments.items)) |exit_code| {
            if (exit_code != 0) return UpgradeError.BackendFailed;
            return;
        }
    }
    try runFlatpak(context, operation_context);
}

fn runAppImage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
) !void {
    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    var manager = Zigalpm.appimage.UpdateManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};

    var updates = try manager.get_updates();
    defer updates.deinit();
    if (updates.items.len == 0) {
        emitStatus(operation_context, .appimage, .success, "No updates available for any AppImage.");
        return;
    }

    var failed = false;
    for (updates.items) |*update| {
        try emitFormattedStatus(
            context,
            operation_context,
            .appimage,
            .information,
            "Updating {s} to {s}",
            .{ update.name, update.version },
        );
        if (!try manager.update(update)) failed = true;
    }
    if (failed) return UpgradeError.BackendFailed;
}

fn reportBackendFailure(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "{s} upgrade step failed: {t}",
        .{ backend.displayName(), err },
    );
    defer context.allocator.free(message);
    var operation = operation_context.begin(.{
        .backend = backend.operationBackend(),
        .kind = .update,
        .subject = backend.displayName(),
    });
    operation.reportError(err, message, "upgrade", null, true);
    operation.finish(.failed);
}

fn emitStatus(
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    level: Zigalpm.OperationStatusLevel,
    message: []const u8,
) void {
    var operation = operation_context.begin(.{
        .backend = backend.operationBackend(),
        .kind = .update,
        .subject = backend.displayName(),
    });
    operation.status(level, message, "upgrade.status", null);
    operation.finish(.success);
}

fn emitFormattedStatus(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    level: Zigalpm.OperationStatusLevel,
    comptime format: []const u8,
    arguments: anytype,
) !void {
    const message = try std.fmt.allocPrint(context.allocator, format, arguments);
    defer context.allocator.free(message);
    emitStatus(operation_context, backend, level, message);
}

fn requiresElevation(invocation: *const parser.Invocation) bool {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path)) return true;
    if (!std.mem.eql(u8, invocation.command.path, all_command_path)) return false;
    return backendEnabled(invocation, .standard) or backendEnabled(invocation, .aur);
}

fn shouldPrepareStandardPreview(
    invocation: *const parser.Invocation,
    running_as_root: bool,
) bool {
    return !running_as_root and
        !invocation.globals.ui_mode and
        !upgradesAll(invocation) and
        std.mem.eql(u8, invocation.command.path, standard_command_path);
}

fn shouldPrepareAllPreview(
    invocation: *const parser.Invocation,
    running_as_root: bool,
) bool {
    return !running_as_root and
        !invocation.globals.ui_mode and
        upgradesAll(invocation);
}

fn upgradesAll(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, all_command_path) or
        optionEnabled(invocation, "--all");
}

fn backendEnabled(invocation: *const parser.Invocation, backend: Backend) bool {
    return switch (backend) {
        .standard => !optionEnabled(invocation, "--no-repo"),
        .aur => !optionEnabled(invocation, "--no-aur"),
        .flatpak => !optionEnabled(invocation, "--no-flatpak"),
        .appimage => !optionEnabled(invocation, "--no-appimage"),
    };
}

fn backendForPath(path: []const u8) ?Backend {
    if (std.mem.eql(u8, path, standard_command_path)) return .standard;
    if (std.mem.eql(u8, path, aur_command_path)) return .aur;
    if (std.mem.eql(u8, path, flatpak_command_path)) return .flatpak;
    if (std.mem.eql(u8, path, appimage_command_path)) return .appimage;
    return null;
}

fn openingMessage(invocation: *const parser.Invocation) []const u8 {
    if (upgradesAll(invocation))
        return "Upgrading all selected package backends...";
    return switch (backendForPath(invocation.command.path) orelse unreachable) {
        .standard => "Performing full system upgrade...",
        .aur => "Upgrading out-of-date AUR packages...",
        .flatpak => "Updating all Flatpak apps and runtimes...",
        .appimage => "Checking for AppImage upgrades...",
    };
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    if (upgradesAll(invocation)) return "All upgrades complete.";
    return switch (backendForPath(invocation.command.path) orelse unreachable) {
        .standard => "System upgraded successfully!",
        .aur => "AUR upgrade complete.",
        .flatpak => "Flatpak upgrade complete.",
        .appimage => "AppImage upgrades complete.",
    };
}

fn failureMessage(invocation: *const parser.Invocation) []const u8 {
    if (upgradesAll(invocation))
        return "One or more upgrade steps failed.";
    return switch (backendForPath(invocation.command.path) orelse unreachable) {
        .standard => "System upgrade failed.",
        .aur => "AUR upgrade failed.",
        .flatpak => "Flatpak upgrade failed.",
        .appimage => "AppImage upgrade failed.",
    };
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn isUpgradePath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, all_command_path) or
        std.mem.eql(u8, path, appimage_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

test "standard upgrade preview runs only before non-root elevation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const standard = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "upgrade", "standard", "--no-confirm" },
    );
    try std.testing.expect(standard == .dispatch);
    try std.testing.expect(shouldPrepareStandardPreview(&standard.dispatch, false));
    try std.testing.expect(!shouldPrepareStandardPreview(&standard.dispatch, true));

    const ui = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "upgrade", "standard", "--ui-mode", "--no-confirm" },
    );
    try std.testing.expect(ui == .dispatch);
    try std.testing.expect(!shouldPrepareStandardPreview(&ui.dispatch, false));

    const all = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "upgrade", "all", "--no-confirm" },
    );
    try std.testing.expect(all == .dispatch);
    try std.testing.expect(!shouldPrepareStandardPreview(&all.dispatch, false));
    try std.testing.expect(shouldPrepareAllPreview(&all.dispatch, false));
    try std.testing.expect(!shouldPrepareAllPreview(&all.dispatch, true));

    const standard_all = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "upgrade", "standard", "--all", "--no-confirm" },
    );
    try std.testing.expect(standard_all == .dispatch);
    try std.testing.expect(upgradesAll(&standard_all.dispatch));
    try std.testing.expect(!shouldPrepareStandardPreview(&standard_all.dispatch, false));
    try std.testing.expect(shouldPrepareAllPreview(&standard_all.dispatch, false));
}

test "combined upgrade plan renders enabled user updates and confirms once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-flatpak",
        "--no-appimage",
    });
    try std.testing.expect(outcome == .dispatch);

    var stdin = std.Io.Reader.fixed("maybe\nyes\n");
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct {
        calls: std.ArrayList(Backend) = .empty,

        fn collect(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            backend: Backend,
        ) !list_updates.Result {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            try self.calls.append(std.testing.allocator, backend);
            try std.testing.expectEqual(Backend.aur, backend);
            return .{ .aur = .{ .items = &.{.{
                .name = "demo-git",
                .version = "1.0",
                .new_version = "1.1",
                .download_size = 42,
                .url = "https://example.invalid/demo-git",
                .package_base = "demo-git",
                .description = "fixture",
            }} } };
        }
    };
    var capture: Capture = .{};
    defer capture.calls.deinit(std.testing.allocator);

    const preview = try prepareAllUpgradePreviewWithCollector(
        &context,
        &outcome.dispatch,
        .{ .data = &capture, .call = Capture.collect },
    );
    try std.testing.expect(preview.has_updates);
    try std.testing.expect(preview.proceed);
    try std.testing.expectEqualSlices(Backend, &.{.aur}, capture.calls.items);

    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Building upgrade plan...") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AUR (1):") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "demo-git: 1.0 -> 1.1") != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, rendered, "Proceed with all upgrades? (Y/n)"),
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Please answer 'y' or 'n'.") != null);
}

test "combined upgrade plan defaults to approval, supports decline, and no-confirm bypasses the prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const Capture = struct {
        fn collect(
            _: ?*anyopaque,
            _: *runtime.RuntimeContext,
            backend: Backend,
        ) !list_updates.Result {
            try std.testing.expectEqual(Backend.appimage, backend);
            return .{ .appimage = .{ .items = &.{.{
                .name = "Demo.AppImage",
                .version = "2.0",
                .download_url = "https://example.invalid/Demo.AppImage",
                .is_update_available = true,
            }} } };
        }
    };
    const collector: PlanCollector = .{ .call = Capture.collect };

    const defaulted = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-aur",
        "--no-flatpak",
    });
    try std.testing.expect(defaulted == .dispatch);
    try std.testing.expect(!requiresElevation(&defaulted.dispatch));
    try std.testing.expect(shouldPrepareAllPreview(&defaulted.dispatch, false));
    var default_stdin = std.Io.Reader.fixed("\n");
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &default_stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const defaulted_preview = try prepareAllUpgradePreviewWithCollector(
        &context,
        &defaulted.dispatch,
        collector,
    );
    try std.testing.expect(defaulted_preview.has_updates);
    try std.testing.expect(defaulted_preview.proceed);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Proceed with all upgrades? (Y/n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Upgrade cancelled.") == null);

    stdout.writer.end = 0;
    var decline_stdin = std.Io.Reader.fixed("n\n");
    context.stdin = &decline_stdin;
    const declined_preview = try prepareAllUpgradePreviewWithCollector(
        &context,
        &defaulted.dispatch,
        collector,
    );
    try std.testing.expect(declined_preview.has_updates);
    try std.testing.expect(!declined_preview.proceed);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Upgrade cancelled.") != null);

    stdout.writer.end = 0;
    context.stdin = null;
    const automatic = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-aur",
        "--no-flatpak",
        "--no-confirm",
    });
    try std.testing.expect(automatic == .dispatch);
    const automatic_preview = try prepareAllUpgradePreviewWithCollector(
        &context,
        &automatic.dispatch,
        collector,
    );
    try std.testing.expect(automatic_preview.has_updates);
    try std.testing.expect(automatic_preview.proceed);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Proceed with all upgrades?") == null);
}

test "upgrade preview size formatting preserves negative net changes" {
    const formatted = try formatUpgradeSize(std.testing.allocator, .megabytes, -1048576);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("-1.00 MiB", formatted);
}

test "upgrade routes every action-first type through the combined handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const paths = [_]struct { arguments: []const []const u8, backend: Backend }{
        .{ .arguments = &.{ "upgrade", "standard", "--no-confirm" }, .backend = .standard },
        .{ .arguments = &.{ "upgrade", "aur", "--check", "--singlepane", "--no-confirm" }, .backend = .aur },
        .{ .arguments = &.{ "upgrade", "flatpak", "--no-confirm" }, .backend = .flatpak },
        .{ .arguments = &.{ "upgrade", "appimage", "--no-confirm" }, .backend = .appimage },
    };
    for (paths) |expected| {
        const outcome = try parser.parse(arena.allocator(), &manifest, expected.arguments);
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
        var observed: ?Backend = null;
        const runner: Runner = .{
            .data = &observed,
            .call = struct {
                fn run(
                    data: ?*anyopaque,
                    _: *runtime.RuntimeContext,
                    operation_context: *Zigalpm.OperationContext,
                    backend: Backend,
                    _: *const parser.Invocation,
                ) !void {
                    const capture: *?Backend = @ptrCast(@alignCast(data.?));
                    capture.* = backend;
                    var operation = operation_context.begin(.{
                        .backend = backend.operationBackend(),
                        .kind = .update,
                        .subject = backend.displayName(),
                    });
                    operation.progress(.{ .completed = 1, .total = 1, .percentage = 100 });
                    operation.finish(.success);
                }
            }.run,
        };

        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
        try std.testing.expectEqual(expected.backend, observed.?);
        try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);
    }
}

test "standard all modifier routes every backend through the combined coordinator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "upgrade", "standard", "--all", "--no-confirm" },
    );
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings("Upgrading all selected package backends...", openingMessage(&outcome.dispatch));

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
    var calls: std.ArrayList(Backend) = .empty;
    defer calls.deinit(std.testing.allocator);
    const runner: Runner = .{
        .data = &calls,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                _: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                const captured: *std.ArrayList(Backend) = @ptrCast(@alignCast(data.?));
                try captured.append(std.testing.allocator, backend);
            }
        }.run,
    };

    try runSelected(runner, &context, &operation_context, &outcome.dispatch);
    try std.testing.expectEqualSlices(Backend, &all_backends, calls.items);
}

test "upgrade all honors every exclusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-flatpak",
        "--no-appimage",
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
    var calls: std.ArrayList(Backend) = .empty;
    defer calls.deinit(std.testing.allocator);
    const runner: Runner = .{
        .data = &calls,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                _: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                const captured: *std.ArrayList(Backend) = @ptrCast(@alignCast(data.?));
                try captured.append(std.testing.allocator, backend);
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualSlices(Backend, &.{.aur}, calls.items);
}

test "upgrade all continues after a failed backend and returns failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "upgrade", "all", "--no-confirm" });
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
    var calls: std.ArrayList(Backend) = .empty;
    defer calls.deinit(std.testing.allocator);
    const runner: Runner = .{
        .data = &calls,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                _: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                const captured: *std.ArrayList(Backend) = @ptrCast(@alignCast(data.?));
                try captured.append(std.testing.allocator, backend);
                if (backend == .aur) return error.SyntheticAurFailure;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualSlices(Backend, &all_backends, calls.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "AUR upgrade step failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction failed.") != null);
}

test "upgrade UI mode emits backend percentage frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "flatpak",
        "--ui-mode",
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
    const runner: Runner = .{
        .call = struct {
            fn run(
                _: ?*anyopaque,
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                var operation = operation_context.begin(.{
                    .backend = backend.operationBackend(),
                    .kind = .update,
                    .subject = "org.example.App",
                });
                operation.progress(.{ .stage = "Updating", .percentage = 44 });
                operation.finish(.success);
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    const rendered = stdout.writer.buffered();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rendered, "[JSON]"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[/JSON]") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}
