const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const fmt = @import("../output/format.zig");
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
const news = @import("news.zig");

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

const Real = struct {
    fn run(
        _: Real,
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
};

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

    return try executeWithRunner(context, invocation, Real{});
}

const PreviewResult = struct {
    has_updates: bool,
    proceed: bool,
};

const RealPlanCollector = struct {
    fn collect(
        _: RealPlanCollector,
        context: *runtime.RuntimeContext,
        backend: Backend,
        invocation: *const parser.Invocation,
    ) !list_updates.Result {
        return list_updates.collectUpdates(context, listUpdatesBackend(backend), optionEnabled(invocation, "--show-hidden"), optionEnabled(invocation, "--no-devel"));
    }
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

fn prepareAllUpgradePreview(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !PreviewResult {
    return prepareAllUpgradePreviewWithCollector(context, invocation, RealPlanCollector{});
}

fn prepareAllUpgradePreviewWithCollector(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    collector: anytype,
) anyerror!PreviewResult {
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
    collector: anytype,
) anyerror!UpgradePlan {
    var plan: UpgradePlan = .{};
    errdefer plan.deinit(context.allocator);

    try context.stdout.writeAll("Building upgrade plan...\n");
    try context.stdout.flush();
    for (all_backends) |backend| {
        if (!backendEnabled(invocation, backend)) continue;
        try context.stdout.print("{s}\n", .{collectingMessage(backend)});
        try context.stdout.flush();

        var result = collector.collect(context, backend, invocation) catch |err| {
            if (backend == .flatpak) {
                if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
                    try output.writeWarning(context, message);
                    continue;
                }
            }
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
        cells[4] = try fmt.formatSignedSize(allocator, size_display, update.size_difference);
        cells[5] = try fmt.formatSignedSize(allocator, size_display, update.download_size);
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
    const formatted_download = try fmt.formatSignedSize(allocator, size_display, total_download);
    const formatted_change = try fmt.formatSignedSize(allocator, size_display, net_change);
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

const SizeDisplay = fmt.SizeDisplay;
const loadSizeDisplay = fmt.loadSizeDisplay;

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
        .{ .use_root = false, .temp_root_path = database_path },
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
        cells[4] = try fmt.formatSignedSize(allocator, size_display, size_change);
        cells[5] = try fmt.formatSignedSize(allocator, size_display, download_size);
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
    const formatted_download = try fmt.formatSignedSize(allocator, size_display, total_download);
    const formatted_change = try fmt.formatSignedSize(allocator, size_display, net_change);
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

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    const Selected = struct {
        inner: @TypeOf(runner),

        pub fn run(
            self: @This(),
            run_context: *runtime.RuntimeContext,
            operation_context: *Zigalpm.OperationContext,
            run_invocation: *const parser.Invocation,
        ) anyerror!void {
            try runSelected(self.inner, run_context, operation_context, run_invocation);
        }
    };
    const selected = Selected{ .inner = runner };
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, selected)
    else
        executeStandard(context, invocation, selected);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    const succeeded = try standard_single_pane.output(
        context,
        openingMessage(invocation),
        invocation.globals.no_confirm,
        runner,
        invocation,
        successMessage(invocation),
        failureMessage(invocation),
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    return ui_operation.runTransaction(context, invocation, .{
        .opening = openingMessage(invocation),
        .success_message = successMessage(invocation),
        .failure_message = failureMessage(invocation),
        .failure_label = "Upgrade failed",
        .report_flatpak_unavailable = true,
    }, runner);
}

fn runSelected(
    runner: anytype,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) anyerror!void {
    if (!upgradesAll(invocation)) {
        try runner.run(
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
        runner.run(context, operation_context, backend, invocation) catch |err| {
            if (backend == .flatpak) {
                if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
                    reportBackendSkipped(operation_context, message);
                    continue;
                }
            }
            failed = true;
            try reportBackendFailure(context, operation_context, backend, err);
        };
    }
    if (failed) return UpgradeError.OneOrMoreBackendsFailed;
}

const all_backends = [_]Backend{ .standard, .aur, .flatpak, .appimage };

fn runStandard(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (!invocation.globals.ui_mode) {
        const result = elevation.runAsInvokingUser(
            context,
            &.{ "news", "standard" },
        ) catch null;

        if (result == null) {
            _ = news.showUnread(context) catch {};
        }
    }
    const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, .{ .use_root = true, .operation_context = operation_context });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    try manager.sync(true);
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
    var cache_operation = operation_context.begin(.{ .backend = .alpm, .kind = .cleanup });
    var cache_completion: Zigalpm.OperationCompletionStatus = .failed;
    defer cache_operation.finish(cache_completion);
    var answer = try cache_operation.ask(.{
        .kind = .confirmation,
        .prompt = "Would you like to remove extra cache entries?",
        .default_response = .accepted,
    });
    defer answer.deinit(context.allocator);
    const clean_up = answer.response == .accepted;
    if (clean_up) {
        var cleaner = Zigalpm.CacheManager.init(context.allocator, context.io, .{ .cache_directory = manager.config.cache_directory, .handle = manager.handle });
        cleaner.setOperationContext(operation_context);
        const plan = try cleaner.plan_cache_cleanup(.{ .keep = 3, .dry_run = false });
        _ = try cleaner.execute_cache_removal_plan(&plan);
    }
    cache_completion = .success;
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

    const updates = try manager.getPackagesNeedingUpdate(!optionEnabled(invocation, "--no-devel"));
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

fn rebaseEolFlatpaks(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    manager: anytype,
) !void {
    const statuses = manager.list_eol_flatpak() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer Zigalpm.flatpak.EolStatus.deinitSlice(context.allocator, statuses);

    for (statuses) |status| {
        const marker = status.eol_rebase orelse {
            if (status.eol) |reason| {
                const warning = try Zigalpm.flatpak.eol.eolOnlyWarning(
                    context.allocator,
                    status.id,
                    status.branch,
                    reason,
                );
                defer context.allocator.free(warning);
                Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .warning, status.id, warning);
            }
            continue;
        };

        const target = Zigalpm.flatpak.eol.parseRebaseTarget(marker, status.branch) orelse {
            const warning = try Zigalpm.flatpak.eol.eolOnlyWarning(
                context.allocator,
                status.id,
                status.branch,
                status.eol,
            );
            defer context.allocator.free(warning);
            Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .warning, status.id, warning);
            continue;
        };

        const new_ref = if (target.reference) |reference|
            try context.allocator.dupe(u8, reference)
        else
            try Zigalpm.flatpak.eol.buildRef(
                context.allocator,
                .app,
                target.id,
                if (Zigalpm.flatpak.eol.parseRef(status.reference)) |parsed| parsed.arch else "x86_64",
                target.branch,
            );
        defer context.allocator.free(new_ref);

        const rebase_ok = manager.rebase_flatpak(
            status.reference,
            new_ref,
            status.origin,
            status.scope,
            &.{status.id},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const warning = try std.fmt.allocPrint(
                    context.allocator,
                    "Failed to rebase {s}: continuing with the upgrade pass.",
                    .{status.id},
                );
                defer context.allocator.free(warning);
                Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .warning, status.id, warning);
                continue;
            },
        };
        if (!rebase_ok) {
            const warning = try std.fmt.allocPrint(
                context.allocator,
                "Failed to rebase {s}: continuing with the upgrade pass.",
                .{status.id},
            );
            defer context.allocator.free(warning);
            Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .warning, status.id, warning);
            continue;
        }

        const message = try Zigalpm.flatpak.eol.rebasedMessage(
            context.allocator,
            status.id,
            target.id,
        );
        defer context.allocator.free(message);
        Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .success, status.id, message);
    }
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    try rebaseEolFlatpaks(context, operation_context, manager);
    if (!try manager.upgrade_flatpaks()) return UpgradeError.BackendFailed;
}

fn runFlatpakStep(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    // Relaunch the Flatpak step as the invoking (non-root) user in every
    // combined upgrade, including --ui-mode runs elevated through pkexec:
    // only that user's process can see the user-level Flatpak installation.
    if (upgradesAll(invocation)) {
        switch (Zigalpm.flatpak.backendStatus()) {
            .available => {},
            .unavailable => return Zigalpm.flatpak.errors.Error.FlatpakBackendUnavailable,
            .incompatible => return Zigalpm.flatpak.errors.Error.FlatpakBackendIncompatible,
        }

        const arguments = try flatpakRelaunchArguments(context.allocator, invocation.globals);
        defer context.allocator.free(arguments);
        if (try elevation.runAsInvokingUser(context, arguments)) |exit_code| {
            if (exit_code != 0) return UpgradeError.BackendFailed;
            return;
        }
    }
    try runFlatpak(context, operation_context);
}

/// Builds the argument vector for relaunching the Flatpak upgrade step as the
/// invoking user. Output-modifying globals are forwarded so the nested
/// invocation speaks the same protocol, including framed UI events.
fn flatpakRelaunchArguments(
    allocator: std.mem.Allocator,
    globals: parser.GlobalOptions,
) ![]const []const u8 {
    var arguments: std.ArrayList([]const u8) = .empty;
    errdefer arguments.deinit(allocator);
    try arguments.appendSlice(allocator, &.{ "upgrade", "flatpak" });
    if (globals.no_confirm)
        try arguments.append(allocator, "--no-confirm");
    if (globals.json)
        try arguments.append(allocator, "--json");
    if (globals.ui_mode)
        try arguments.append(allocator, "--ui-mode");
    return arguments.toOwnedSlice(allocator);
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

fn reportBackendSkipped(
    operation_context: *Zigalpm.OperationContext,
    reason: []const u8,
) void {
    var operation = operation_context.begin(.{
        .backend = .flatpak,
        .kind = .update,
        .subject = "Flatpak",
    });
    operation.status(.warning, reason, "flatpak.backend_unavailable", null);
    operation.finish(.success);
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
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-flatpak",
        "--no-appimage",
    });
    try std.testing.expect(outcome == .dispatch);

    var stdin = std.Io.Reader.fixed("maybe\nyes\n");
    tc.context.stdin = &stdin;
    const Capture = struct {
        calls: std.ArrayList(Backend) = .empty,

        fn collect(
            self: *@This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            _: *const parser.Invocation,
        ) !list_updates.Result {
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
        &tc.context,
        &outcome.dispatch,
        &capture,
    );
    try std.testing.expect(preview.has_updates);
    try std.testing.expect(preview.proceed);
    try std.testing.expectEqualSlices(Backend, &.{.aur}, capture.calls.items);

    const rendered = tc.stdout.writer.buffered();
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
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    const Capture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            _: *const parser.Invocation,
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
    const collector = Capture{};

    const defaulted = try parser.parse(tc.arena.allocator(), &manifest, &.{
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
    tc.context.stdin = &default_stdin;
    const defaulted_preview = try prepareAllUpgradePreviewWithCollector(
        &tc.context,
        &defaulted.dispatch,
        collector,
    );
    try std.testing.expect(defaulted_preview.has_updates);
    try std.testing.expect(defaulted_preview.proceed);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Proceed with all upgrades? (Y/n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Upgrade cancelled.") == null);

    tc.stdout.writer.end = 0;
    var decline_stdin = std.Io.Reader.fixed("n\n");
    tc.context.stdin = &decline_stdin;
    const declined_preview = try prepareAllUpgradePreviewWithCollector(
        &tc.context,
        &defaulted.dispatch,
        collector,
    );
    try std.testing.expect(declined_preview.has_updates);
    try std.testing.expect(!declined_preview.proceed);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Upgrade cancelled.") != null);

    tc.stdout.writer.end = 0;
    tc.context.stdin = null;
    const automatic = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-aur",
        "--no-flatpak",
        "--no-confirm",
    });
    try std.testing.expect(automatic == .dispatch);
    const automatic_preview = try prepareAllUpgradePreviewWithCollector(
        &tc.context,
        &automatic.dispatch,
        collector,
    );
    try std.testing.expect(automatic_preview.has_updates);
    try std.testing.expect(automatic_preview.proceed);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Proceed with all upgrades?") == null);
}

test "upgrade preview size formatting preserves negative net changes" {
    const formatted = try fmt.formatSignedSize(std.testing.allocator, .megabytes, -1048576);
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
        const Observed = struct {
            backend: ?Backend = null,

            fn run(
                self: *@This(),
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                self.backend = backend;
                var operation = operation_context.begin(.{
                    .backend = backend.operationBackend(),
                    .kind = .update,
                    .subject = backend.displayName(),
                });
                operation.progress(.{ .completed = 1, .total = 1, .percentage = 100 });
                operation.finish(.success);
            }
        };
        var observed: Observed = .{};

        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, &observed));
        try std.testing.expectEqual(expected.backend, observed.backend.?);
        try std.testing.expect(std.mem.indexOf(
            u8,
            stdout.writer.buffered(),
            successMessage(&outcome.dispatch),
        ) != null);
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
    const Calls = struct {
        backends: std.ArrayList(Backend) = .empty,

        fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            backend: Backend,
            _: *const parser.Invocation,
        ) !void {
            try self.backends.append(std.testing.allocator, backend);
        }
    };
    var calls: Calls = .{};
    defer calls.backends.deinit(std.testing.allocator);

    try runSelected(&calls, &context, &operation_context, &outcome.dispatch);
    try std.testing.expectEqualSlices(Backend, &all_backends, calls.backends.items);
}

test "upgrade all honors every exclusion" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-flatpak",
        "--no-appimage",
        "--no-confirm",
    });
    try std.testing.expect(outcome == .dispatch);

    const Calls = struct {
        backends: std.ArrayList(Backend) = .empty,

        fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            backend: Backend,
            _: *const parser.Invocation,
        ) !void {
            try self.backends.append(std.testing.allocator, backend);
        }
    };
    var calls: Calls = .{};
    defer calls.backends.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &calls));
    try std.testing.expectEqualSlices(Backend, &.{.aur}, calls.backends.items);
}

test "upgrade all continues after a failed backend and returns failure" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "upgrade", "all", "--no-confirm" });
    try std.testing.expect(outcome == .dispatch);

    const Calls = struct {
        backends: std.ArrayList(Backend) = .empty,

        fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            backend: Backend,
            _: *const parser.Invocation,
        ) !void {
            try self.backends.append(std.testing.allocator, backend);
            if (backend == .aur) return error.SyntheticAurFailure;
        }
    };
    var calls: Calls = .{};
    defer calls.backends.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&tc.context, &outcome.dispatch, &calls));
    try std.testing.expectEqualSlices(Backend, &all_backends, calls.backends.items);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "AUR upgrade step failed") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        ":: One or more upgrade steps failed.",
    ) != null);
}

test "upgrade all treats an unavailable Flatpak backend as a warning" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "upgrade", "all", "--no-confirm" },
    );
    try std.testing.expect(outcome == .dispatch);

    const Calls = struct {
        backends: std.ArrayList(Backend) = .empty,

        fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            backend: Backend,
            _: *const parser.Invocation,
        ) !void {
            try self.backends.append(std.testing.allocator, backend);
            if (backend == .flatpak)
                return error.FlatpakBackendUnavailable;
        }
    };
    var calls: Calls = .{};
    defer calls.backends.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&tc.context, &outcome.dispatch, &calls),
    );
    try std.testing.expectEqualSlices(Backend, &all_backends, calls.backends.items);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        "Install shelly-flatpak-backend and Flatpak",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stdout.writer.buffered(),
        ":: All upgrades complete.",
    ) != null);
}

test "upgrade UI mode emits backend percentage frames" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "upgrade",
        "flatpak",
        "--ui-mode",
        "--no-confirm",
    });
    try std.testing.expect(outcome == .dispatch);

    const Progress = struct {
        fn run(
            _: @This(),
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
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, Progress{}));
    const rendered = tc.stdout.writer.buffered();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rendered, "[JSON]"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[/JSON]") != null);
    try std.testing.expectEqual(@as(usize, 0), tc.stderr.writer.buffered().len);
}

test "no-devel modifier reaches the AUR backend selection on aur and all upgrades" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    const Capture = struct {
        backends: std.ArrayList(Backend) = .empty,
        flag_missing: bool = false,

        fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            backend: Backend,
            invocation: *const parser.Invocation,
        ) !void {
            try self.backends.append(std.testing.allocator, backend);
            if (!optionEnabled(invocation, "--no-devel")) self.flag_missing = true;
        }
    };
    var capture: Capture = .{};
    defer capture.backends.deinit(std.testing.allocator);

    const aur_outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "upgrade", "aur", "--no-confirm", "--no-devel" },
    );
    try std.testing.expect(aur_outcome == .dispatch);
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &aur_outcome.dispatch, &capture));
    try std.testing.expectEqualSlices(Backend, &.{.aur}, capture.backends.items);
    try std.testing.expect(!capture.flag_missing);

    const all_outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "upgrade", "all", "--no-confirm", "--no-devel" },
    );
    try std.testing.expect(all_outcome == .dispatch);
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &all_outcome.dispatch, &capture));
    try std.testing.expectEqualSlices(Backend, &all_backends, capture.backends.items[1..]);
    try std.testing.expect(!capture.flag_missing);

    const default_outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "upgrade", "aur", "--no-confirm" },
    );
    try std.testing.expect(default_outcome == .dispatch);
    try std.testing.expect(!optionEnabled(&default_outcome.dispatch, "--no-devel"));

    const scoped_outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "upgrade", "standard", "--no-devel" },
    );
    try std.testing.expect(scoped_outcome == .failure);
}

test "flatpak relaunch forwards output modifiers to the nested invocation" {
    const ui_arguments = try flatpakRelaunchArguments(
        std.testing.allocator,
        parser.GlobalOptions{ .no_confirm = true, .ui_mode = true },
    );
    defer std.testing.allocator.free(ui_arguments);
    const expected_ui = [_][]const u8{ "upgrade", "flatpak", "--no-confirm", "--ui-mode" };
    try std.testing.expectEqualSlices([]const u8, &expected_ui, ui_arguments);

    const json_arguments = try flatpakRelaunchArguments(
        std.testing.allocator,
        parser.GlobalOptions{ .json = true },
    );
    defer std.testing.allocator.free(json_arguments);
    const expected_json = [_][]const u8{ "upgrade", "flatpak", "--json" };
    try std.testing.expectEqualSlices([]const u8, &expected_json, json_arguments);

    const plain_arguments = try flatpakRelaunchArguments(std.testing.allocator, .{});
    defer std.testing.allocator.free(plain_arguments);
    const expected_plain = [_][]const u8{ "upgrade", "flatpak" };
    try std.testing.expectEqualSlices([]const u8, &expected_plain, plain_arguments);
}

const EolUpgradeTestManager = struct {
    allocator: std.mem.Allocator,
    statuses: []const Zigalpm.flatpak.EolStatus = &.{},
    list_error: bool = false,
    rebase_result: bool = true,
    rebase_error: bool = false,
    rebase_called: usize = 0,
    rebase_old_refs: std.ArrayList([]const u8) = .empty,
    rebase_new_refs: std.ArrayList([]const u8) = .empty,
    rebase_previous_ids: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *EolUpgradeTestManager) void {
        for (self.rebase_old_refs.items) |value| self.allocator.free(value);
        self.rebase_old_refs.deinit(self.allocator);
        for (self.rebase_new_refs.items) |value| self.allocator.free(value);
        self.rebase_new_refs.deinit(self.allocator);
        for (self.rebase_previous_ids.items) |value| self.allocator.free(value);
        self.rebase_previous_ids.deinit(self.allocator);
    }

    pub fn list_eol_flatpak(self: @This()) ![]Zigalpm.flatpak.EolStatus {
        if (self.list_error) return error.TestListFailure;
        const result = try self.allocator.alloc(Zigalpm.flatpak.EolStatus, self.statuses.len);
        for (self.statuses, result) |source, *dest| {
            dest.* = try cloneEolStatus(self.allocator, source);
        }
        return result;
    }

    pub fn rebase_flatpak(
        self: *@This(),
        old_ref: []const u8,
        new_ref: []const u8,
        _: []const u8,
        _: Zigalpm.flatpak.Scope,
        previous_ids: []const []const u8,
    ) !bool {
        self.rebase_called += 1;
        if (self.rebase_error) return error.TestRebaseFailure;
        try self.rebase_old_refs.append(self.allocator, try self.allocator.dupe(u8, old_ref));
        try self.rebase_new_refs.append(self.allocator, try self.allocator.dupe(u8, new_ref));
        // Only the first previous_id is relevant for the test assertions.
        if (previous_ids.len > 0)
            try self.rebase_previous_ids.append(self.allocator, try self.allocator.dupe(u8, previous_ids[0]));
        return self.rebase_result;
    }
};

fn cloneEolStatus(allocator: std.mem.Allocator, source: Zigalpm.flatpak.EolStatus) !Zigalpm.flatpak.EolStatus {
    return .{
        .reference = try allocator.dupe(u8, source.reference),
        .id = try allocator.dupe(u8, source.id),
        .branch = try allocator.dupe(u8, source.branch),
        .origin = try allocator.dupe(u8, source.origin),
        .scope = source.scope,
        .eol = if (source.eol) |value| try allocator.dupe(u8, value) else null,
        .eol_rebase = if (source.eol_rebase) |value| try allocator.dupe(u8, value) else null,
    };
}

fn makeEolStatus(
    id: []const u8,
    branch: []const u8,
    eol: ?[]const u8,
    eol_rebase: ?[]const u8,
) Zigalpm.flatpak.EolStatus {
    return .{
        .reference = @constCast("app/dev.bragefuglseth.Keypunch/x86_64/stable"),
        .id = @constCast(id),
        .branch = @constCast(branch),
        .origin = @constCast("flathub"),
        .scope = .system,
        .eol = if (eol) |value| @constCast(value) else null,
        .eol_rebase = if (eol_rebase) |value| @constCast(value) else null,
    };
}

test "Flatpak upgrade rebases all EOL refs with replacements automatically" {
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

    const statuses = [_]Zigalpm.flatpak.EolStatus{
        makeEolStatus("dev.bragefuglseth.Keypunch", "stable", null, "no.bragefuglseth.Keypunch"),
        makeEolStatus("org.example.Dead", "stable", "No longer maintained", null),
    };

    var manager: EolUpgradeTestManager = .{
        .allocator = arena.allocator(),
        .statuses = &statuses,
    };
    defer manager.deinit();

    try rebaseEolFlatpaks(&context, &operations, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.rebase_called);
    try std.testing.expectEqualStrings(
        "app/dev.bragefuglseth.Keypunch/x86_64/stable",
        manager.rebase_old_refs.items[0],
    );
    try std.testing.expectEqualStrings(
        "app/no.bragefuglseth.Keypunch/x86_64/stable",
        manager.rebase_new_refs.items[0],
    );
    try std.testing.expectEqualStrings("dev.bragefuglseth.Keypunch", manager.rebase_previous_ids.items[0]);
}

test "Flatpak upgrade warns and continues when a rebase fails" {
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

    const statuses = [_]Zigalpm.flatpak.EolStatus{
        makeEolStatus("dev.bragefuglseth.Keypunch", "stable", null, "no.bragefuglseth.Keypunch"),
        makeEolStatus("org.example.Other", "stable", null, "org.example.New"),
    };

    var manager: EolUpgradeTestManager = .{
        .allocator = arena.allocator(),
        .statuses = &statuses,
        .rebase_error = true,
    };
    defer manager.deinit();

    try rebaseEolFlatpaks(&context, &operations, &manager);
    // Both rebases were attempted despite the first failing.
    try std.testing.expectEqual(@as(usize, 2), manager.rebase_called);
}

test "Flatpak upgrade handles an empty EOL list gracefully" {
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

    var manager: EolUpgradeTestManager = .{
        .allocator = arena.allocator(),
        .statuses = &.{},
    };
    defer manager.deinit();

    try rebaseEolFlatpaks(&context, &operations, &manager);
    try std.testing.expectEqual(@as(usize, 0), manager.rebase_called);
}

test "Flatpak upgrade treats list_eol failures as advisory" {
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

    var manager: EolUpgradeTestManager = .{
        .allocator = arena.allocator(),
        .list_error = true,
    };
    defer manager.deinit();

    try rebaseEolFlatpaks(&context, &operations, &manager);
    try std.testing.expectEqual(@as(usize, 0), manager.rebase_called);
}
