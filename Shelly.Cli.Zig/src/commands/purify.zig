const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const table = @import("../output/table.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");

const standard_command_path = "shelly purify standard";
const flatpak_command_path = "shelly purify flatpak";

pub const Backend = enum { standard, flatpak };

const PurifyError = error{
    BackendFailed,
    CachePlanMissing,
};

const Options = struct {
    dry_run: bool = false,
    orphans: bool = false,
    cache_versions: ?usize = null,
    plan_only: bool = false,
    cache_plan: ?*const Zigalpm.alpm.CacheRemovalPlan = null,
};

const Result = struct {
    targets: []const [:0]const u8 = &.{},
    owns_targets: bool = false,
    cache_plan: ?Zigalpm.alpm.CacheRemovalPlan = null,

    fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.owns_targets) {
            for (self.targets) |target| allocator.free(target);
            allocator.free(self.targets);
        }
        if (self.cache_plan) |*cache_plan| cache_plan.deinit(allocator);
        self.* = undefined;
    }
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        backend: Backend,
        options: Options,
    ) anyerror!Result,
};

const RunnerAdapter = struct {
    runner: Runner,
    backend: Backend,
    options: Options,
    result: ?Result = null,

    fn call(
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        const self: *RunnerAdapter = @ptrCast(@alignCast(data.?));
        self.result = try self.runner.call(
            self.runner.data,
            context,
            operation_context,
            self.backend,
            self.options,
        );
    }
};

const real_runner: Runner = .{ .call = runReal };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    const backend = backendForPath(invocation.command.path) orelse return null;
    if (backend == .standard and !invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate purify: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }
    return dispatchWithRunner(context, invocation, real_runner);
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !?u8 {
    const backend = backendForPath(invocation.command.path) orelse return null;
    const options = optionsFor(invocation);
    var plan = buildPlan(context, backend, options, runner) catch |err| {
        try writePlanFailure(context, invocation, backend, err);
        return 1;
    };
    defer plan.deinit(context.allocator);

    try writePlan(context, invocation, backend, options, plan.targets);
    if (plan.targets.len == 0 or options.dry_run) return 0;

    if (!invocation.globals.no_confirm) {
        const confirmed = if (invocation.globals.ui_mode)
            try confirmPurifyUi(context, backend)
        else
            try confirmPurify(context);
        if (!confirmed) return 0;
    }
    var execution_options = options;
    if (plan.cache_plan) |*cache_plan| execution_options.cache_plan = cache_plan;
    return try executeWithRunner(context, invocation, backend, execution_options, runner);
}

fn buildPlan(
    context: *runtime.RuntimeContext,
    backend: Backend,
    options: Options,
    runner: Runner,
) !Result {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    var plan_options = options;
    plan_options.plan_only = true;
    return runner.call(
        runner.data,
        context,
        &operation_context,
        backend,
        plan_options,
    );
}

fn confirmPurify(context: *runtime.RuntimeContext) !bool {
    const reader = context.stdin orelse {
        try context.stdout.writeAll("Operation cancelled: confirmation input is unavailable.\n");
        try context.stdout.flush();
        return false;
    };
    while (true) {
        try context.stdout.writeAll("Proceed with purify? (y/N) ");
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse {
            try context.stdout.writeAll("\nOperation cancelled.\n");
            try context.stdout.flush();
            return false;
        };
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "n") or
            std.ascii.eqlIgnoreCase(answer, "no"))
        {
            try context.stdout.writeAll("Operation cancelled.\n");
            try context.stdout.flush();
            return false;
        }
        if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))
            return true;
        try context.stdout.writeAll("Please answer 'y' or 'n'.\n");
    }
}

fn confirmPurifyUi(context: *runtime.RuntimeContext, backend: Backend) !bool {
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
        .backend = if (backend == .standard) .alpm else .flatpak,
        .kind = .remove,
    });
    var answer = try operation.ask(.{
        .kind = .confirmation,
        .prompt = "Proceed with purify?",
        .default_response = .declined,
    });
    defer answer.deinit(context.allocator);
    const accepted = answer.response == .accepted;
    operation.finish(if (accepted) .success else .cancelled);
    if (!accepted) try output.writeInfoFrame(context, "Operation cancelled.");
    try ui_operation.flush(context);
    return accepted;
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    options: Options,
    runner: Runner,
) !u8 {
    if (invocation.globals.ui_mode)
        return executeUi(context, invocation, backend, options, runner);
    if (invocation.globals.json and invocation.globals.no_confirm)
        return executeQuiet(context, invocation, backend, options, runner);
    return executeStandard(context, invocation, backend, options, runner);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    options: Options,
    runner: Runner,
) !u8 {
    var adapter: RunnerAdapter = .{
        .runner = runner,
        .backend = backend,
        .options = options,
    };
    defer if (adapter.result) |*result| result.deinit(context.allocator);
    const succeeded = try standard_single_pane.output(
        context,
        openingMessage(backend, options),
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = RunnerAdapter.call },
    );
    if (!succeeded) return 1;
    if (adapter.result == null) return 1;
    return 0;
}

fn executeQuiet(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    options: Options,
    runner: Runner,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    if (invocation.globals.no_confirm) {
        operation_context.setQuestionHandler(.{ .function = ui_operation.acceptQuestionDefaults });
        defer operation_context.setQuestionHandler(null);
    }

    var result = runner.call(
        runner.data,
        context,
        &operation_context,
        backend,
        options,
    ) catch |err| {
        try context.stderr.print("Purify failed: {t}\n", .{err});
        return 1;
    };
    defer result.deinit(context.allocator);
    return 0;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    options: Options,
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
    const subscription = try operation_context.subscribe(.{
        .function = ui_operation.Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(subscription);

    try output.writeAlpmInfoFrame(context, "TransactionStart", openingMessage(backend, options));
    try ui_operation.flush(context);

    var result = runner.call(
        runner.data,
        context,
        &operation_context,
        backend,
        options,
    ) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Purify failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", failureMessage(backend));
        try ui_operation.flush(context);
        return 1;
    };
    defer result.deinit(context.allocator);

    try output.writeAlpmInfoFrame(context, "TransactionDone", successMessage(backend, options));
    try ui_operation.flush(context);
    return if (reporter.failed()) 1 else 0;
}

fn runReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    options: Options,
) !Result {
    switch (backend) {
        .standard => {
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
            const planning = options.plan_only or options.dry_run;

            if (!planning and options.cache_versions != null) {
                const cache_plan = options.cache_plan orelse return PurifyError.CachePlanMissing;
                var cache_manager = Zigalpm.alpm.CacheManager.init(
                    context.allocator,
                    context.io,
                    .{
                        .cache_directory = cache_plan.cache_directory,
                        .handle = manager.handle,
                    },
                );
                cache_manager.setOperationContext(operation_context);
                _ = try cache_manager.execute_cache_removal_plan(cache_plan);
            }

            var result: Result = .{
                .targets = try manager.purify(planning, options.orphans, true),
                .owns_targets = true,
            };
            errdefer result.deinit(context.allocator);

            if (planning) {
                if (options.cache_versions) |keep| {
                    var cache_manager = Zigalpm.alpm.CacheManager.init(
                        context.allocator,
                        context.io,
                        .{
                            .cache_directory = manager.config.cache_directory,
                            .handle = manager.handle,
                        },
                    );
                    cache_manager.setOperationContext(operation_context);
                    var cache_plan = try cache_manager.plan_cache_cleanup(.{
                        .keep = keep,
                        .dry_run = options.dry_run,
                    });
                    errdefer cache_plan.deinit(context.allocator);
                    try appendCacheTargets(context.allocator, &result, &cache_plan);
                    result.cache_plan = cache_plan;
                }
            }
            return result;
        },
        .flatpak => {
            var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
            defer manager.deinit();
            try manager.setOperationContext(operation_context);
            defer manager.setOperationContext(null) catch {};
            if (options.plan_only or options.dry_run) {
                const dependencies = try manager.list_unused_dependencies();
                defer Zigalpm.flatpak.UnusedDependency.deinitSlice(context.allocator, dependencies);
                const targets = try context.allocator.alloc([:0]const u8, dependencies.len);
                var initialized: usize = 0;
                errdefer {
                    for (targets[0..initialized]) |target| context.allocator.free(target);
                    context.allocator.free(targets);
                }
                for (dependencies, targets) |dependency, *target| {
                    target.* = try std.fmt.allocPrintSentinel(
                        context.allocator,
                        "[{s}] {s}",
                        .{ scopeName(dependency.scope), dependency.reference },
                        0,
                    );
                    initialized += 1;
                }
                return .{ .targets = targets, .owns_targets = true };
            }
            if (!try manager.remove_unused_dependencies()) return PurifyError.BackendFailed;
            return .{};
        },
    }
}

fn appendCacheTargets(
    allocator: std.mem.Allocator,
    result: *Result,
    cache_plan: *const Zigalpm.alpm.CacheRemovalPlan,
) !void {
    std.debug.assert(result.owns_targets);
    var additional: usize = 0;
    for (cache_plan.items) |item| {
        if (!cacheTargetAlreadyPresent(result.targets, item.package.full_path)) additional += 1;
    }
    if (additional == 0) return;

    const combined = try allocator.alloc([:0]const u8, result.targets.len + additional);
    @memcpy(combined[0..result.targets.len], result.targets);
    var initialized = result.targets.len;
    errdefer {
        for (combined[result.targets.len..initialized]) |target| allocator.free(target);
        allocator.free(combined);
    }
    for (cache_plan.items) |item| {
        if (cacheTargetAlreadyPresent(result.targets, item.package.full_path)) continue;
        combined[initialized] = try std.fmt.allocPrintSentinel(
            allocator,
            "[cache] {s} {s} ({d} B)",
            .{
                item.package.name,
                item.package.version_release,
                item.package.file_size +| item.signature_size,
            },
            0,
        );
        initialized += 1;
    }

    if (result.owns_targets) allocator.free(result.targets);
    result.targets = combined;
    result.owns_targets = true;
}

fn cacheTargetAlreadyPresent(
    targets: []const [:0]const u8,
    cache_path: []const u8,
) bool {
    const basename = std.fs.path.basename(cache_path);
    for (targets) |target| {
        if (std.mem.eql(u8, target, cache_path) or std.mem.eql(u8, target, basename)) return true;
    }
    return false;
}

fn scopeName(scope: anytype) []const u8 {
    return switch (scope) {
        .SYSTEM => "system",
        .USER => "user",
        .UNKNOWN => "unknown",
    };
}

fn writePlan(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    options: Options,
    targets: []const [:0]const u8,
) !void {
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(context, "TransactionStart", planMessage(backend));
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeTargetsJson(&payload.writer, targets);
        try output.writeFrame(context, payload.writer.buffered());
        try output.writeAlpmInfoFrame(
            context,
            "TransactionDone",
            if (options.dry_run) "Dry run complete." else planSummary(targets.len),
        );
        try ui_operation.flush(context);
        return;
    }
    if (invocation.globals.json) {
        try writeTargetsJson(context.stdout, targets);
        try context.stdout.writeByte('\n');
        return;
    }
    if (targets.len == 0) {
        try output.writeSuccess(context, "No packages found to purify!");
        return;
    }

    try output.writeSuccess(context, if (options.dry_run) "Running would remove:" else "Packages to remove:");
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const rows = try storage.allocator().alloc([]const []const u8, targets.len);
    for (targets, rows) |target, *row|
        row.* = try storage.allocator().dupe([]const u8, &.{target});
    try table.write(
        context.allocator,
        context.stdout,
        &.{"Package"},
        rows,
        output.supportsAnsi(context),
    );
}

fn planMessage(backend: Backend) []const u8 {
    return switch (backend) {
        .standard => "Building standard package purify plan...",
        .flatpak => "Building Flatpak dependency cleanup plan...",
    };
}

fn planSummary(target_count: usize) []const u8 {
    return switch (target_count) {
        0 => "No packages found to purify.",
        1 => "Purify plan contains 1 target.",
        else => "Purify plan is ready for confirmation.",
    };
}

fn writePlanFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to build the {s} purify plan: {t}",
        .{ @tagName(backend), err },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else if (invocation.globals.json)
        try context.stderr.print("{s}\n", .{message})
    else
        try output.writeFailure(context, message);
}

fn writeTargetsJson(writer: *std.Io.Writer, targets: []const [:0]const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (targets) |target| try json.write(target);
    try json.endArray();
}

fn optionsFor(invocation: *const parser.Invocation) Options {
    return .{
        .dry_run = optionEnabled(invocation, "--dry-run"),
        .orphans = optionEnabled(invocation, "--orphans"),
        .cache_versions = optionalUnsigned(invocation, "--cache", 3),
    };
}

fn optionalUnsigned(
    invocation: *const parser.Invocation,
    name: []const u8,
    default_value: usize,
) ?usize {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return default_value;
        return std.fmt.parseInt(usize, value, 10) catch unreachable;
    }
    return null;
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn backendForPath(path: []const u8) ?Backend {
    if (std.mem.eql(u8, path, standard_command_path)) return .standard;
    if (std.mem.eql(u8, path, flatpak_command_path)) return .flatpak;
    return null;
}

fn openingMessage(backend: Backend, options: Options) []const u8 {
    return switch (backend) {
        .standard => if (options.dry_run) "Checking packages to purify..." else "Purifying packages...",
        .flatpak => "Removing unused Flatpak dependencies...",
    };
}

fn successMessage(backend: Backend, options: Options) []const u8 {
    return switch (backend) {
        .standard => if (options.dry_run) "Dry run complete." else "Packages purified.",
        .flatpak => "Unused Flatpak dependency cleanup completed.",
    };
}

fn failureMessage(backend: Backend) []const u8 {
    return switch (backend) {
        .standard => "Package purification failed.",
        .flatpak => "Flatpak dependency cleanup failed.",
    };
}

test "recognizes standard and Flatpak purify paths" {
    try std.testing.expectEqual(Backend.standard, backendForPath(standard_command_path).?);
    try std.testing.expectEqual(Backend.flatpak, backendForPath(flatpak_command_path).?);
    try std.testing.expect(backendForPath("shelly purify keyring") == null);
}

test "purify long forms and shortcodes route with standard modifiers" {
    const spec = @import("../cli/spec.zig");
    const shortcodes = @import("../cli/shortcodes.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "purify", "standard", "--dry-run", "--cache", "--orphans" },
    );
    try std.testing.expectEqualStrings(standard_command_path, outcome.dispatch.command.path);
    const options = optionsFor(&outcome.dispatch);
    try std.testing.expect(options.dry_run);
    try std.testing.expect(options.orphans);
    try std.testing.expectEqual(@as(?usize, 3), options.cache_versions);

    outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "purify", "standard", "--cache=5" },
    );
    try std.testing.expectEqual(@as(?usize, 5), optionsFor(&outcome.dispatch).cache_versions);

    outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "purify", "standard", "-c", "0", "--orphans" },
    );
    try std.testing.expectEqual(@as(?usize, 0), optionsFor(&outcome.dispatch).cache_versions);

    const invalid_cache = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "purify", "standard", "--cache=-1" },
    );
    try std.testing.expect(invalid_cache == .failure);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "purify", "standard" });
    try std.testing.expect(optionsFor(&outcome.dispatch).cache_versions == null);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "purify", "flatpak" });
    try std.testing.expectEqualStrings(flatpak_command_path, outcome.dispatch.command.path);
    const flatpak_cache = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "purify", "flatpak", "--cache" },
    );
    try std.testing.expect(flatpak_cache == .failure);

    const standard = try shortcodes.translate(arena.allocator(), &manifest, &.{"-Zsdoc"});
    try std.testing.expectEqual(@as(usize, 5), standard.translated.len);
    const expected_standard = [_][]const u8{ "purify", "standard", "-d", "-o", "-c" };
    for (standard.translated, &expected_standard) |actual, expected|
        try std.testing.expectEqualStrings(expected, actual);
    const flatpak = try shortcodes.translate(arena.allocator(), &manifest, &.{"-Zf"});
    try std.testing.expectEqual(@as(usize, 2), flatpak.translated.len);
    const expected_flatpak = [_][]const u8{ "purify", "flatpak" };
    for (flatpak.translated, &expected_flatpak) |actual, expected|
        try std.testing.expectEqualStrings(expected, actual);
}

test "purify confirmation is default deny" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var stdin = std.Io.Reader.fixed("maybe\nyes\n");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };

    try std.testing.expect(try confirmPurify(&context));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stdout.writer.buffered(), "(y/N)"));

    stdout.writer.end = 0;
    var declined = std.Io.Reader.fixed("\n");
    context.stdin = &declined;
    try std.testing.expect(!try confirmPurify(&context));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Operation cancelled.") != null);
}

test "destructive purify shows its plan before confirmation and mutates only after acceptance" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "purify", "standard", "--orphans", "--cache",
    });
    var stdin = std.Io.Reader.fixed("n\n");
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
        plan_calls: usize = 0,
        mutation_calls: usize = 0,

        fn run(
            data: ?*anyopaque,
            runtime_context: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: Backend,
            options: Options,
        ) !Result {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (options.plan_only) {
                self.plan_calls += 1;
                try std.testing.expect(options.orphans);
                try std.testing.expectEqual(@as(?usize, 3), options.cache_versions);
                const cache_directory = try runtime_context.allocator.dupe(u8, "/tmp/cache");
                errdefer runtime_context.allocator.free(cache_directory);
                const cache_items = try runtime_context.allocator.alloc(Zigalpm.alpm.CacheRemovalItem, 0);
                return .{
                    .targets = &.{ "orphan-one", "[cache] cached-one 1.0-1 (12 B)" },
                    .cache_plan = .{
                        .cache_directory = cache_directory,
                        .items = cache_items,
                        .package_bytes = 12,
                        .signature_bytes = 0,
                        .dry_run = false,
                    },
                };
            }
            self.mutation_calls += 1;
            try std.testing.expectEqual(@as(?usize, 3), options.cache_versions);
            try std.testing.expect(options.cache_plan != null);
            return .{};
        }
    };
    var capture: Capture = .{};
    const runner: Runner = .{ .data = &capture, .call = Capture.run };

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, runner),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.plan_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.mutation_calls);
    const declined_output = stdout.writer.buffered();
    const plan_index = std.mem.indexOf(u8, declined_output, "cached-one").?;
    const prompt_index = std.mem.indexOf(u8, declined_output, "Proceed with purify?").?;
    try std.testing.expect(plan_index < prompt_index);

    stdout.writer.end = 0;
    var accepted = std.Io.Reader.fixed("yes\n");
    context.stdin = &accepted;
    capture = .{};
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, runner),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.plan_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.mutation_calls);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Transaction complete") != null);
}

test "empty purify plans skip confirmation and backend mutation" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "purify", "flatpak" });
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
    const Capture = struct {
        calls: usize = 0,

        fn run(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: Backend,
            options: Options,
        ) !Result {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            try std.testing.expect(options.plan_only);
            return .{};
        }
    };
    var capture: Capture = .{};

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, .{ .data = &capture, .call = Capture.run }),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "No packages found") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Proceed with purify?") == null);
}

test "no-confirm JSON emits one plan before quiet execution" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "purify", "standard", "--json", "--no-confirm",
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
    const Capture = struct {
        calls: usize = 0,

        fn run(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: Backend,
            options: Options,
        ) !Result {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            return if (options.plan_only)
                .{ .targets = &.{"bad-cache.pkg.tar.zst"} }
            else
                .{};
        }
    };
    var capture: Capture = .{};

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, .{ .data = &capture, .call = Capture.run }),
    );
    try std.testing.expectEqualStrings("[\"bad-cache.pkg.tar.zst\"]\n", stdout.writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "routes purify backends and preserves standard result formats" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
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
    const Capture = struct {
        calls: usize = 0,

        fn run(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            backend: Backend,
            options: Options,
        ) !Result {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            if (options.plan_only) {
                if (backend == .standard) {
                    try std.testing.expect(options.orphans);
                    return .{ .targets = &.{ "orphan-one", "bad-cache.pkg.tar.zst" } };
                }
                return .{ .targets = &.{"[user] runtime/org.example.Platform/x86_64/stable"} };
            }
            return .{};
        }
    };
    var capture: Capture = .{};
    const runner: Runner = .{ .data = &capture, .call = Capture.run };

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "purify", "standard", "--dry-run", "--orphans", "--json",
    });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, runner),
    );
    try std.testing.expectEqualStrings(
        "[\"orphan-one\",\"bad-cache.pkg.tar.zst\"]\n",
        stdout.writer.buffered(),
    );

    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "purify", "flatpak", "--no-confirm" });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, runner),
    );
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Transaction complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "runtime/org.example.Platform") != null);
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
}

test "purify UI emits result and transaction frames" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "purify", "standard", "--ui-mode", "--dry-run",
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
    const Success = struct {
        fn run(
            _: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: Backend,
            _: Options,
        ) !Result {
            return .{ .targets = &.{"orphan-one"} };
        }
    };

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, .{ .call = Success.run }),
    );
    const rendered = stdout.writer.buffered();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rendered, "[JSON]"));

    var iterator = std.mem.splitSequence(u8, rendered, "[JSON]");
    _ = iterator.next();
    var found_targets = false;
    while (iterator.next()) |framed| {
        const end = std.mem.indexOf(u8, framed, "[/JSON]") orelse continue;
        const encoded = framed[0..end];
        const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try arena.allocator().alloc(u8, size);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        if (std.mem.indexOf(u8, decoded, "[\"orphan-one\"]") != null) found_targets = true;
    }
    try std.testing.expect(found_targets);
}

test "purify UI presents the plan before a compatible confirmation frame" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "purify", "flatpak", "--ui-mode",
    });
    const response_json = "{\"$kind\":\"a.yesno\",\"QuestionId\":\"1\",\"Accept\":true}";
    const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
    const encoded = try arena.allocator().alloc(u8, encoded_size);
    const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
    const response_frame = try std.fmt.allocPrint(
        arena.allocator(),
        "[JSON]{s}[/JSON]\n",
        .{encoded_response},
    );
    var stdin = std.Io.Reader.fixed(response_frame);
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
        mutation_calls: usize = 0,

        fn run(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: Backend,
            options: Options,
        ) !Result {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (options.plan_only)
                return .{ .targets = &.{"[user] runtime/org.example.Platform/x86_64/stable"} };
            self.mutation_calls += 1;
            return .{};
        }
    };
    var capture: Capture = .{};

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(
            &context,
            &outcome.dispatch,
            .{ .data = &capture, .call = Capture.run },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.mutation_calls);

    var iterator = std.mem.splitSequence(u8, stdout.writer.buffered(), "[JSON]");
    _ = iterator.next();
    var frame_index: usize = 0;
    var plan_index: ?usize = null;
    var question_index: ?usize = null;
    while (iterator.next()) |framed| : (frame_index += 1) {
        const end = std.mem.indexOf(u8, framed, "[/JSON]") orelse continue;
        const payload = framed[0..end];
        const size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const decoded = try arena.allocator().alloc(u8, size);
        try std.base64.standard.Decoder.decode(decoded, payload);
        if (std.mem.indexOf(u8, decoded, "runtime/org.example.Platform") != null)
            plan_index = frame_index;
        if (std.mem.indexOf(u8, decoded, "\"$kind\":\"q.yesno\"") != null) {
            question_index = frame_index;
            try std.testing.expect(std.mem.indexOf(u8, decoded, "\"QuestionKind\":\"RemovePkgs\"") != null);
        }
    }
    try std.testing.expect(plan_index != null);
    try std.testing.expect(question_index != null);
    try std.testing.expect(plan_index.? < question_index.?);
}

test "purify backend failures return nonzero" {
    const spec = @import("../cli/spec.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "purify", "flatpak" });
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
    const Failure = struct {
        fn run(
            _: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: Backend,
            _: Options,
        ) !Result {
            return error.TestBackendFailure;
        }
    };

    try std.testing.expectEqual(
        @as(?u8, 1),
        try dispatchWithRunner(&context, &outcome.dispatch, .{ .call = Failure.run }),
    );
}
