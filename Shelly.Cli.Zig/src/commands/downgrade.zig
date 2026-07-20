const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const table = @import("../output/table.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const shortcodes = @import("../cli/shortcodes.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");

const command_path = "shelly downgrade standard";

const DowngradeError = error{
    PackageNotInstalled,
    TargetNotFound,
};

const CandidateSet = struct {
    candidates: []Zigalpm.alpm.DowngradeCandidate,
    owns_candidates: bool = false,

    fn deinit(self: *CandidateSet, allocator: std.mem.Allocator) void {
        if (self.owns_candidates)
            Zigalpm.alpm.DowngradeCandidate.deinitSlice(allocator, self.candidates);
        self.* = undefined;
    }
};

const Runner = struct {
    data: ?*anyopaque = null,
    discover: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        package_name: []const u8,
    ) anyerror!CandidateSet,
    install: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        candidate: *const Zigalpm.alpm.DowngradeCandidate,
    ) anyerror!void,
    ignore: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        package_name: []const u8,
    ) anyerror!void,
};

const InstallAdapter = struct {
    runner: Runner,
    candidate: *const Zigalpm.alpm.DowngradeCandidate,

    fn call(
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        const self: *InstallAdapter = @ptrCast(@alignCast(data.?));
        try self.runner.install(
            self.runner.data,
            context,
            operation_context,
            self.candidate,
        );
    }
};

const real_runner: Runner = .{
    .discover = discoverReal,
    .install = installReal,
    .ignore = ignoreReal,
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (validationMessage(invocation)) |message|
        return try reportFailure(context, invocation, message);

    if (!invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate downgrade: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }
    return try runWithRunner(context, invocation, real_runner);
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (validationMessage(invocation)) |message|
        return try reportFailure(context, invocation, message);
    return try runWithRunner(context, invocation, runner);
}

fn runWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    const package_name = invocation.positionals[0];
    if (!invocation.globals.ui_mode and !invocation.globals.json) {
        const looking_message = try std.fmt.allocPrint(
            context.allocator,
            "Looking for downgrade options for: {s}",
            .{package_name},
        );
        defer context.allocator.free(looking_message);
        try output.writeSuccess(context, looking_message);
    }

    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    var candidates = runner.discover(
        runner.data,
        context,
        &operation_context,
        package_name,
    ) catch |err| {
        return try reportDiscoveryFailure(context, invocation, package_name, err);
    };
    defer candidates.deinit(context.allocator);

    if (candidates.candidates.len == 0) {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "No downgrade options found for: {s}",
            .{package_name},
        );
        defer context.allocator.free(message);
        return try reportFailure(context, invocation, message);
    }

    if (optionEnabled(invocation, "--list-options")) {
        try writeCandidates(context, invocation, package_name, candidates.candidates);
        return 0;
    }

    const target = targetValue(invocation);
    if (invocation.globals.ui_mode and target == null)
        return try reportFailure(
            context,
            invocation,
            "UI mode downgrade requires --target. Use --list-options to inspect available versions.",
        );

    const selected = selectCandidate(
        context,
        invocation,
        candidates.candidates,
        target,
    ) catch |err| switch (err) {
        DowngradeError.TargetNotFound => {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "No downgrade option matched '{s}'. Use --list-options to inspect valid targets.",
                .{target.?},
            );
            defer context.allocator.free(message);
            return try reportFailure(context, invocation, message);
        },
        else => return err,
    };

    if (invocation.globals.ui_mode)
        return executeUi(context, invocation, package_name, selected, runner);

    if (!invocation.globals.no_confirm and
        !try confirm(context, "Do you want to proceed with the installation?", true))
    {
        try context.stdout.writeAll("Operation Cancelled.\n");
        return 0;
    }

    if (!try executeStandard(context, invocation, selected, runner)) {
        try output.writeFailure(context, "Downgrade failed. See errors above.");
        return 1;
    }

    var add_ignore = optionEnabled(invocation, "--ignore");
    if (!add_ignore and !invocation.globals.no_confirm)
        add_ignore = try confirm(context, "Do you want to add package to IgnorePkg list?", true);
    if (add_ignore) {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Adding to IgnorePkg: {s}",
            .{package_name},
        );
        defer context.allocator.free(message);
        try output.writeSuccess(context, message);
        if (!try executeIgnore(context, invocation, package_name, runner)) return 1;
    }

    try output.writeSuccess(context, "Downgrade complete.");
    return 0;
}

fn validationMessage(invocation: *const parser.Invocation) ?[]const u8 {
    if (invocation.positionals.len == 0 or
        std.mem.trim(u8, invocation.positionals[0], " \t\r\n").len == 0)
        return "Error: No package specified.";
    const has_target = targetValue(invocation) != null;
    if (has_target and optionEnabled(invocation, "--oldest"))
        return "Error: Cannot combine --target with --oldest.";
    if (has_target and optionEnabled(invocation, "--list-options"))
        return "Error: Cannot combine --target with --list-options.";
    return null;
}

fn reportDiscoveryFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    package_name: []const u8,
    err: anyerror,
) !u8 {
    if (err == DowngradeError.PackageNotInstalled)
        return reportFailure(context, invocation, "Error: Package must be installed to downgrade");
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to find downgrade options for {s}: {t}",
        .{ package_name, err },
    );
    defer context.allocator.free(message);
    return reportFailure(context, invocation, message);
}

fn reportFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
    } else if (invocation.globals.json) {
        try context.stderr.print("{s}\n", .{message});
    } else {
        try output.writeFailure(context, message);
    }
    try ui_operation.flush(context);
    return 1;
}

fn selectCandidate(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    candidates: []const Zigalpm.alpm.DowngradeCandidate,
    target: ?[]const u8,
) !*const Zigalpm.alpm.DowngradeCandidate {
    if (target) |requested| return resolveTarget(candidates, requested);
    if (optionEnabled(invocation, "--oldest")) return &candidates[candidates.len - 1];
    if (invocation.globals.no_confirm) return &candidates[0];
    return &candidates[try promptForCandidate(context, candidates)];
}

fn resolveTarget(
    candidates: []const Zigalpm.alpm.DowngradeCandidate,
    target: []const u8,
) DowngradeError!*const Zigalpm.alpm.DowngradeCandidate {
    const filename_target = std.mem.indexOf(u8, target, ".pkg.tar.") != null;
    for (candidates) |*candidate| {
        const value = if (filename_target) candidate.filename else candidate.version_release;
        if (std.mem.eql(u8, value, target)) return candidate;
    }
    return DowngradeError.TargetNotFound;
}

fn promptForCandidate(
    context: *runtime.RuntimeContext,
    candidates: []const Zigalpm.alpm.DowngradeCandidate,
) !usize {
    const reader = context.stdin orelse return 0;
    try context.stdout.writeAll("Select Package\n");
    for (0..candidates.len) |index| {
        const candidate = candidates[candidates.len - 1 - index];
        try context.stdout.print("  {d}) {s} ({s}", .{
            index + 1,
            candidate.filename,
            locationName(candidate),
        });
        if (candidate.source.is_remote()) {
            if (uriHost(candidate.location)) |host| try context.stdout.print(": {s}", .{host});
        }
        try context.stdout.writeAll(")\n");
    }
    while (true) {
        try context.stdout.print("Select [1-{d}] ({d}): ", .{ candidates.len, candidates.len });
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse return 0;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0) return 0;
        const selection = std.fmt.parseInt(usize, answer, 10) catch continue;
        if (selection >= 1 and selection <= candidates.len) return candidates.len - selection;
    }
}

fn confirm(
    context: *runtime.RuntimeContext,
    prompt: []const u8,
    default_value: bool,
) !bool {
    const reader = context.stdin orelse return default_value;
    while (true) {
        try context.stdout.print("{s} ({s}) ", .{
            prompt,
            if (default_value) "Y/n" else "y/N",
        });
        try context.stdout.flush();
        const input = (try reader.takeDelimiter('\n')) orelse return default_value;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0) return default_value;
        if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))
            return true;
        if (std.ascii.eqlIgnoreCase(answer, "n") or std.ascii.eqlIgnoreCase(answer, "no"))
            return false;
        try context.stdout.writeAll("Please answer 'y' or 'n'.\n");
    }
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    candidate: *const Zigalpm.alpm.DowngradeCandidate,
    runner: Runner,
) !bool {
    const opening = try std.fmt.allocPrint(
        context.allocator,
        "Installing: {s}",
        .{candidate.filename},
    );
    defer context.allocator.free(opening);
    var adapter: InstallAdapter = .{ .runner = runner, .candidate = candidate };
    return standard_single_pane.output(
        context,
        opening,
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = InstallAdapter.call },
    );
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    package_name: []const u8,
    candidate: *const Zigalpm.alpm.DowngradeCandidate,
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

    const opening = try std.fmt.allocPrint(
        context.allocator,
        "Installing {s} {s}...",
        .{ candidate.name, candidate.filename },
    );
    defer context.allocator.free(opening);
    try output.writeAlpmInfoFrame(context, "TransactionStart", opening);
    try ui_operation.flush(context);

    runner.install(runner.data, context, &operation_context, candidate) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Downgrade failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", "Downgrade failed.");
        try ui_operation.flush(context);
        return 1;
    };
    if (optionEnabled(invocation, "--ignore")) {
        runner.ignore(runner.data, context, &operation_context, package_name) catch |err| {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "Failed to add package to IgnorePkg: {t}",
                .{err},
            );
            defer context.allocator.free(message);
            try output.writeErrorFrame(context, message);
            try output.writeAlpmInfoFrame(context, "TransactionFailed", "Package downgraded, but IgnorePkg could not be updated.");
            try ui_operation.flush(context);
            return 1;
        };
    }

    try output.writeAlpmInfoFrame(context, "TransactionDone", "Package downgraded successfully!");
    try ui_operation.flush(context);
    return if (reporter.failed()) 1 else 0;
}

fn executeIgnore(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    package_name: []const u8,
    runner: Runner,
) !bool {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    runner.ignore(runner.data, context, &operation_context, package_name) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Error adding {s} to IgnorePkg: {t}",
            .{ package_name, err },
        );
        defer context.allocator.free(message);
        _ = try reportFailure(context, invocation, message);
        return false;
    };
    return true;
}

fn writeCandidates(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    package_name: []const u8,
    candidates: []const Zigalpm.alpm.DowngradeCandidate,
) !void {
    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeCandidatesJson(&payload.writer, candidates, true);
        try output.writeFrame(context, payload.writer.buffered());
        return;
    }
    if (invocation.globals.json) {
        try writeCandidatesJson(context.stdout, candidates, false);
        try context.stdout.writeByte('\n');
        return;
    }

    const heading = try std.fmt.allocPrint(
        context.allocator,
        "Available downgrade options for: {s}",
        .{package_name},
    );
    defer context.allocator.free(heading);
    try output.writeSuccess(context, heading);

    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const rows = try allocator.alloc([]const []const u8, candidates.len);
    for (rows, 0..) |*cells, index| {
        const candidate = candidates[candidates.len - 1 - index];
        const values = try allocator.alloc([]const u8, 3);
        values[0] = candidate.filename;
        values[1] = locationName(candidate);
        values[2] = if (candidate.is_installed) "True" else "False";
        cells.* = values;
    }
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Filename", "Location", "Installed" },
        rows,
        output.supportsAnsi(context),
    );
}

fn writeCandidatesJson(
    writer: *std.Io.Writer,
    candidates: []const Zigalpm.alpm.DowngradeCandidate,
    ui_mode: bool,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    var remaining = candidates.len;
    while (remaining > 0) {
        remaining -= 1;
        const candidate = candidates[remaining];
        try json.beginObject();
        try json.objectField("Name");
        try json.write(candidate.name);
        try json.objectField("Filename");
        try json.write(candidate.filename);
        try json.objectField("Location");
        if (ui_mode)
            try json.write(locationName(candidate))
        else
            try json.write(@as(u8, if (candidate.source.is_remote()) 0 else 1));
        try json.objectField("IsInstalled");
        try json.write(candidate.is_installed);
        if (!ui_mode) {
            try json.objectField("Uri");
            if (candidate.source.is_remote())
                try json.write(candidate.location)
            else
                try json.write(null);
        }
        try json.endObject();
    }
    try json.endArray();
}

fn locationName(candidate: Zigalpm.alpm.DowngradeCandidate) []const u8 {
    return if (candidate.source.is_remote()) "Remote" else "Local";
}

fn uriHost(uri: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, uri, "://") orelse return null;
    const start = scheme + 3;
    if (start >= uri.len) return null;
    const slash = std.mem.indexOfScalarPos(u8, uri, start, '/') orelse uri.len;
    const colon = std.mem.indexOfScalarPos(u8, uri, start, ':') orelse slash;
    const end = @min(slash, colon);
    return if (end > start) uri[start..end] else null;
}

fn discoverReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    package_name: []const u8,
) !CandidateSet {
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

    const package_name_z = try context.allocator.dupeZ(u8, package_name);
    defer context.allocator.free(package_name_z);
    const installed = try manager.get_single_installed_package(package_name_z) orelse
        return DowngradeError.PackageNotInstalled;

    var archive = Zigalpm.alpm.ArchiveManager.init(context.allocator, context.io, .{});
    defer archive.deinit();
    archive.setOperationContext(operation_context);
    defer archive.setOperationContext(null);
    return .{
        .candidates = try archive.find_candidates(
            manager,
            package_name,
            installed.version(),
        ),
        .owns_candidates = true,
    };
}

fn installReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    candidate: *const Zigalpm.alpm.DowngradeCandidate,
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

    var archive = Zigalpm.alpm.ArchiveManager.init(context.allocator, context.io, .{});
    defer archive.deinit();
    archive.setOperationContext(operation_context);
    defer archive.setOperationContext(null);
    try archive.install_candidate(manager, candidate, .{});
}

fn ignoreReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    package_name: []const u8,
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
    try manager.ignore_package(package_name);
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

fn targetValue(invocation: *const parser.Invocation) ?[]const u8 {
    const value = optionValue(invocation, "--target") orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

test "downgrade is a root-default command and retains its explicit standard path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{ "downgrade", "linux" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings(command_path, outcome.dispatch.command.path);
    try std.testing.expectEqualStrings("linux", outcome.dispatch.positionals[0]);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "downgrade", "standard", "linux" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqualStrings(command_path, outcome.dispatch.command.path);

    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "downgrade", "-o", "-i", "linux" });
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--oldest"));
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--ignore"));

    const translation = try shortcodes.translate(arena.allocator(), &manifest, &.{ "-Doi", "linux" });
    const translated = translation.arguments().?;
    try std.testing.expectEqualStrings("downgrade", translated[0]);
    try std.testing.expectEqualStrings("-o", translated[1]);
    try std.testing.expectEqualStrings("-i", translated[2]);
}

test "downgrade validation rejects missing packages and incompatible target modes" {
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
    const unused_runner: Runner = .{
        .discover = struct {
            fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: []const u8) !CandidateSet {
                return error.ShouldNotRun;
            }
        }.run,
        .install = struct {
            fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const Zigalpm.alpm.DowngradeCandidate) !void {
                return error.ShouldNotRun;
            }
        }.run,
        .ignore = struct {
            fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: []const u8) !void {
                return error.ShouldNotRun;
            }
        }.run,
    };

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{"downgrade"});
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&context, &outcome.dispatch, unused_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "No package specified") != null);

    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--target", "1.0-1", "--oldest", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&context, &outcome.dispatch, unused_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Cannot combine --target with --oldest") != null);

    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--target", "1.0-1", "--list-options", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&context, &outcome.dispatch, unused_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Cannot combine --target with --list-options") != null);
}

test "downgrade lists candidates as C sharp compatible JSON and UI records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var candidates = [_]Zigalpm.alpm.DowngradeCandidate{
        testCandidate("demo", "2.0", "1", "2.0-1", "x86_64", "demo-2.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-2.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "1.0", "2", "1.0-2", "x86_64", "demo-1.0-2-x86_64.pkg.tar.zst", "/var/cache/pacman/pkg/demo-1.0-2-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var capture: TestRunner = .{ .candidates = &candidates };
    const runner = capture.runner();
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

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "--json", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
    const json_output = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"Location\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"Location\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"Uri\":null") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json_output, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, json_output, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );

    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "--ui-mode", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "[JSON]") != null);
    const decoded = try decodeFirstFrame(arena.allocator(), stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Location\":\"Remote\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Location\":\"Local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Uri\"") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, decoded, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, decoded, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );

    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
    const plain_output = stdout.writer.buffered();
    try std.testing.expect(
        std.mem.indexOf(u8, plain_output, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, plain_output, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );
}

test "downgrade selects oldest and exact targets and updates IgnorePkg only when requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var candidates = [_]Zigalpm.alpm.DowngradeCandidate{
        testCandidate("demo", "3.0", "1", "3.0-1", "x86_64", "demo-3.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-3.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "2.0", "4", "2.0-4", "x86_64", "demo-2.0-4-x86_64.pkg.tar.zst", "/cache/demo-2.0-4-x86_64.pkg.tar.zst", .local_cache, false),
        testCandidate("demo", "1.0", "2", "1.0-2", "x86_64", "demo-1.0-2-x86_64.pkg.tar.zst", "https://archive.example/demo-1.0-2-x86_64.pkg.tar.zst", .arch_linux, false),
    };
    var capture: TestRunner = .{ .candidates = &candidates };
    const runner = capture.runner();
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

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--oldest", "--ignore", "--no-confirm", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualStrings("demo-1.0-2-x86_64.pkg.tar.zst", capture.installed_filename.?);
    try std.testing.expectEqual(@as(usize, 1), capture.ignore_calls);

    capture.installed_filename = null;
    capture.ignore_calls = 0;
    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "downgrade", "--target", "2.0-4", "--no-confirm", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualStrings("demo-2.0-4-x86_64.pkg.tar.zst", capture.installed_filename.?);
    try std.testing.expectEqual(@as(usize, 0), capture.ignore_calls);
}

test "interactive downgrade selection and confirmations are honored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var candidates = [_]Zigalpm.alpm.DowngradeCandidate{
        testCandidate("demo", "2.0", "1", "2.0-1", "x86_64", "demo-2.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-2.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "1.0", "1", "1.0-1", "x86_64", "demo-1.0-1-x86_64.pkg.tar.zst", "/cache/demo-1.0-1-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var capture: TestRunner = .{ .candidates = &candidates };
    var stdin = std.Io.Reader.fixed("1\ny\nn\n");
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
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "downgrade", "demo" });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&context, &outcome.dispatch, capture.runner()),
    );
    try std.testing.expectEqualStrings("demo-1.0-1-x86_64.pkg.tar.zst", capture.installed_filename.?);
    try std.testing.expectEqual(@as(usize, 0), capture.ignore_calls);
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Select Package") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "demo-1.0-1-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, rendered, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Select [1-2] (2):") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do you want to proceed with the installation?") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do you want to add package to IgnorePkg list?") != null);
}

const TestRunner = struct {
    candidates: []Zigalpm.alpm.DowngradeCandidate,
    installed_filename: ?[]const u8 = null,
    ignore_calls: usize = 0,

    fn runner(self: *TestRunner) Runner {
        return .{
            .data = self,
            .discover = discover,
            .install = install,
            .ignore = ignore,
        };
    }

    fn discover(
        data: ?*anyopaque,
        _: *runtime.RuntimeContext,
        _: *Zigalpm.OperationContext,
        _: []const u8,
    ) !CandidateSet {
        const self: *TestRunner = @ptrCast(@alignCast(data.?));
        return .{ .candidates = self.candidates };
    }

    fn install(
        data: ?*anyopaque,
        _: *runtime.RuntimeContext,
        _: *Zigalpm.OperationContext,
        candidate: *const Zigalpm.alpm.DowngradeCandidate,
    ) !void {
        const self: *TestRunner = @ptrCast(@alignCast(data.?));
        self.installed_filename = candidate.filename;
    }

    fn ignore(
        data: ?*anyopaque,
        _: *runtime.RuntimeContext,
        _: *Zigalpm.OperationContext,
        _: []const u8,
    ) !void {
        const self: *TestRunner = @ptrCast(@alignCast(data.?));
        self.ignore_calls += 1;
    }
};

fn testCandidate(
    name: [:0]const u8,
    version: [:0]const u8,
    release: [:0]const u8,
    version_release: [:0]const u8,
    architecture: [:0]const u8,
    filename: []const u8,
    location: []const u8,
    source: Zigalpm.alpm.ArchiveSource,
    is_installed: bool,
) Zigalpm.alpm.DowngradeCandidate {
    return .{
        .name = @constCast(name),
        .version = @constCast(version),
        .release = @constCast(release),
        .version_release = @constCast(version_release),
        .architecture = @constCast(architecture),
        .filename = @constCast(filename),
        .location = @constCast(location),
        .source = source,
        .is_installed = is_installed,
        .size = null,
    };
}

fn decodeFirstFrame(allocator: std.mem.Allocator, rendered: []const u8) ![]const u8 {
    const prefix = "[JSON]";
    const suffix = "[/JSON]";
    const start = (std.mem.indexOf(u8, rendered, prefix) orelse return error.MissingFrame) + prefix.len;
    const relative_end = std.mem.indexOf(u8, rendered[start..], suffix) orelse return error.MissingFrame;
    const encoded = rendered[start .. start + relative_end];
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, size);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}
