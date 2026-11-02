const std = @import("std");
const diagnostics = @import("diagnostics");
const PackageManager = @import("PackageManager");
const test_support = @import("test_support.zig");
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

const DowngradeCandidate = PackageManager.Manager.DowngradeCandidate;

const DowngradeError = error{
    PackageNotInstalled,
    TargetNotFound,
};

const CandidateSet = struct {
    candidates: []DowngradeCandidate,
    owns_candidates: bool = false,

    fn deinit(self: *CandidateSet, allocator: std.mem.Allocator) void {
        if (self.owns_candidates)
            DowngradeCandidate.deinitSlice(allocator, self.candidates);
        self.* = undefined;
    }
};

/// Candidates discovered for one requested package.
const PackageGroup = struct {
    name: []const u8,
    candidates: []DowngradeCandidate,
    owns_candidates: bool,

    fn deinit(self: *PackageGroup, allocator: std.mem.Allocator) void {
        if (self.owns_candidates)
            DowngradeCandidate.deinitSlice(allocator, self.candidates);
        self.* = undefined;
    }
};

const Real = struct {
    fn discover(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *PackageManager.OperationContext,
        package_name: []const u8,
    ) !CandidateSet {
        const manager = try PackageManager.Manager.init(context.allocator, context.environ, .{ .config_path = context.config_path, .use_root = true, .operation_context = operation_context });
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);

        const package_name_z = try context.allocator.dupeSentinel(u8, package_name, 0);
        defer context.allocator.free(package_name_z);
        var installed = try manager.get_single_installed_package(package_name_z) orelse
            return DowngradeError.PackageNotInstalled;
        defer installed.deinit(context.allocator);

        var archive = PackageManager.Manager.ArchiveManager.init(context.allocator, context.io, .{});
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

    fn install(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *PackageManager.OperationContext,
        candidates: []const *const DowngradeCandidate,
    ) !void {
        const manager = try PackageManager.Manager.init(context.allocator, context.environ, .{ .config_path = context.config_path, .use_root = true, .operation_context = operation_context });
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);

        var archive = PackageManager.Manager.ArchiveManager.init(context.allocator, context.io, .{});
        defer archive.deinit();
        archive.setOperationContext(operation_context);
        defer archive.setOperationContext(null);
        try archive.install_candidates(manager, candidates, .{});
    }

    fn ignore(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *PackageManager.OperationContext,
        package_names: []const []const u8,
    ) !void {
        const manager = try PackageManager.Manager.init(context.allocator, context.environ, .{ .config_path = context.config_path, .use_root = true, .operation_context = operation_context });
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);
        try manager.ignore_packages(package_names);
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (try validationMessage(context, invocation)) |message|
        return try reportFailure(context, invocation, message);

    if (!invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Could not obtain administrator privileges for the downgrade. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics.cause(err), @errorName(err) });
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }
    return try runWithRunner(context, invocation, Real{});
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    if (try validationMessage(context, invocation)) |message|
        return try reportFailure(context, invocation, message);
    return try runWithRunner(context, invocation, runner);
}

fn runWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    const package_names = try requestedPackages(context, invocation);

    if (!invocation.globals.ui_mode and !invocation.globals.json) {
        const looking_message = try std.fmt.allocPrint(
            context.allocator,
            "Looking for downgrade options for: {s}",
            .{try std.mem.join(context.allocator, ", ", package_names)},
        );
        defer context.allocator.free(looking_message);
        try output.writeSuccess(context, looking_message);
    }

    var operation_context = PackageManager.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();

    var groups: std.ArrayList(PackageGroup) = .empty;
    defer deinitGroups(context.allocator, &groups);
    for (package_names) |package_name| {
        const discovered = runner.discover(
            context,
            &operation_context,
            package_name,
        ) catch |err| {
            return try reportDiscoveryFailure(context, invocation, package_name, err);
        };
        try groups.append(context.allocator, .{
            .name = package_name,
            .candidates = discovered.candidates,
            .owns_candidates = discovered.owns_candidates,
        });
        if (discovered.candidates.len == 0) {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "No older version of {0f} was found in the configured downgrade sources. Check the available versions before selecting a downgrade target.",
                .{diagnostics.safe(package_name)},
            );
            defer context.allocator.free(message);
            return try reportFailure(context, invocation, message);
        }
    }

    if (optionEnabled(invocation, "--list-options")) {
        try writeCandidates(context, invocation, groups.items);
        return 0;
    }

    const target = targetValue(invocation);
    if (invocation.globals.ui_mode) {
        if (package_names.len != 1)
            return try reportFailure(
                context,
                invocation,
                "UI mode downgrade supports one package at a time. Downgrade the packages separately or use the terminal CLI for multiple packages.",
            );
        if (target == null)
            return try reportFailure(
                context,
                invocation,
                "UI mode downgrade requires --target. Use --list-options to inspect available versions.",
            );
    }

    var selected: std.ArrayList(*const DowngradeCandidate) = .empty;
    for (groups.items) |*group| {
        const candidate = selectCandidate(
            context,
            invocation,
            group.name,
            group.candidates,
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
        try selected.append(context.allocator, candidate);
    }

    if (invocation.globals.ui_mode)
        return executeUi(context, invocation, groups.items[0], selected.items[0], runner);

    if (!invocation.globals.no_confirm and
        !try confirm(context, "Do you want to proceed with the installation?", true))
    {
        try context.stdout.writeAll("Operation cancelled.\n");
        return 0;
    }

    if (!try executeStandard(context, invocation, selected.items, runner)) {
        try output.writeFailure(context, "Could not downgrade the requested package.");
        return 1;
    }

    const ignored = try ignoredPackages(context, invocation, package_names);
    if (ignored.len > 0) {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Adding to IgnorePkg: {s}",
            .{try std.mem.join(context.allocator, ", ", ignored)},
        );
        defer context.allocator.free(message);
        try output.writeSuccess(context, message);
        if (!try executeIgnore(context, invocation, ignored, runner)) return 1;
    }

    try output.writeSuccess(context, "Downgrade complete.");
    return 0;
}

/// Requested package names in argument order, trimmed and deduplicated. The
/// returned slice is owned by the context allocator.
fn requestedPackages(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (invocation.positionals) |positional| {
        const name = std.mem.trim(u8, positional, " \t\r\n");
        if (name.len == 0) continue;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) break;
        } else try names.append(context.allocator, name);
    }
    return names.items;
}

fn deinitGroups(allocator: std.mem.Allocator, groups: *std.ArrayList(PackageGroup)) void {
    for (groups.items) |*group| group.deinit(allocator);
    groups.deinit(allocator);
}

fn validationMessage(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?[]const u8 {
    const package_names = try requestedPackages(context, invocation);
    if (package_names.len == 0)
        return "Specify at least one package name. See the command help for usage.";
    const has_target = targetValue(invocation) != null;
    if (has_target and package_names.len > 1)
        return "Cannot combine --target with multiple packages.";
    if (has_target and optionEnabled(invocation, "--oldest"))
        return "Cannot combine --target with --oldest.";
    if (has_target and optionEnabled(invocation, "--list-options"))
        return "Cannot combine --target with --list-options.";
    return null;
}

fn reportDiscoveryFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    package_name: []const u8,
    err: anyerror,
) !u8 {
    if (err == DowngradeError.PackageNotInstalled) {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Could not downgrade {0f} because it is not installed. Check the package name and installed-package list.",
            .{diagnostics.safe(package_name)},
        );
        defer context.allocator.free(message);
        return reportFailure(context, invocation, message);
    }
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Could not find downgrade options for {0f}: {1s}\n\nTechnical details: {2s}",
        .{ diagnostics.safe(package_name), diagnostics.cause(err), @errorName(err) },
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
    package_name: []const u8,
    candidates: []const DowngradeCandidate,
    target: ?[]const u8,
) !*const DowngradeCandidate {
    if (target) |requested| return resolveTarget(candidates, requested);
    if (optionEnabled(invocation, "--oldest")) return &candidates[candidates.len - 1];
    if (invocation.globals.no_confirm) return &candidates[0];
    return &candidates[try promptForCandidate(context, package_name, candidates)];
}

fn resolveTarget(
    candidates: []const DowngradeCandidate,
    target: []const u8,
) DowngradeError!*const DowngradeCandidate {
    const filename_target = std.mem.indexOf(u8, target, ".pkg.tar.") != null;
    for (candidates) |*candidate| {
        const value = if (filename_target) candidate.filename else candidate.version_release;
        if (std.mem.eql(u8, value, target)) return candidate;
    }
    return DowngradeError.TargetNotFound;
}

fn promptForCandidate(
    context: *runtime.RuntimeContext,
    package_name: []const u8,
    candidates: []const DowngradeCandidate,
) !usize {
    const reader = context.stdin orelse return 0;
    try context.stdout.print("Select Package: {s}\n", .{package_name});
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
    candidates: []const *const DowngradeCandidate,
    runner: anytype,
) anyerror!bool {
    var filenames: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| try filenames.append(context.allocator, candidate.filename);
    const opening = try std.fmt.allocPrint(
        context.allocator,
        "Installing: {s}",
        .{try std.mem.join(context.allocator, ", ", filenames.items)},
    );
    defer context.allocator.free(opening);
    const InstallAdapter = struct {
        runner: @TypeOf(runner),
        candidates: []const *const DowngradeCandidate,

        pub fn run(
            self: @This(),
            runtime_context: *runtime.RuntimeContext,
            operation_context: *PackageManager.OperationContext,
            _: *const parser.Invocation,
        ) !void {
            return self.runner.install(runtime_context, operation_context, self.candidates);
        }
    };
    return standard_single_pane.output(
        context,
        opening,
        invocation.globals.no_confirm,
        InstallAdapter{ .runner = runner, .candidates = candidates },
        invocation,
        null,
        null,
    );
}

/// Determines which downgraded packages join IgnorePkg. `--ignore` adds every
/// package; interactive mode asks per package; `--no-confirm` adds none.
fn ignoredPackages(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    package_names: []const []const u8,
) ![]const []const u8 {
    if (optionEnabled(invocation, "--ignore")) return package_names;
    if (invocation.globals.no_confirm) return &.{};
    var selected: std.ArrayList([]const u8) = .empty;
    for (package_names) |package_name| {
        const question = try std.fmt.allocPrint(
            context.allocator,
            "Do you want to add {s} to IgnorePkg list?",
            .{package_name},
        );
        defer context.allocator.free(question);
        if (try confirm(context, question, true))
            try selected.append(context.allocator, package_name);
    }
    return selected.items;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    group: PackageGroup,
    candidate: *const DowngradeCandidate,
    runner: anytype,
) anyerror!u8 {
    var operation_context = PackageManager.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
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

    const candidates = [_]*const DowngradeCandidate{candidate};
    runner.install(context, &operation_context, candidates[0..]) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Could not downgrade the requested package. {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(err), @errorName(err) });
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", "Could not downgrade the requested package.");
        try ui_operation.flush(context);
        return 1;
    };
    if (optionEnabled(invocation, "--ignore")) {
        const package_names = [_][]const u8{group.name};
        runner.ignore(context, &operation_context, package_names[0..]) catch |err| {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "The package was downgraded, but the requested package could not be added to IgnorePkg. {0s} It may be upgraded again until the ignore setting is saved.\n\nTechnical details: {1s}",
                .{ diagnostics.cause(err), @errorName(err) },
            );
            defer context.allocator.free(message);
            try output.writeErrorFrame(context, message);
            try output.writeAlpmInfoFrame(context, "TransactionFailed", "The package was downgraded, but the requested package could not be added to IgnorePkg. It may be upgraded again until the ignore setting is saved.");
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
    package_names: []const []const u8,
    runner: anytype,
) anyerror!bool {
    var operation_context = PackageManager.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();
    runner.ignore(context, &operation_context, package_names) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "The package was downgraded, but {0f} could not be added to IgnorePkg. {1s} It may be upgraded again until the ignore setting is saved.\n\nTechnical details: {2s}",
            .{ diagnostics.safe(try std.mem.join(context.allocator, ", ", package_names)), diagnostics.cause(err), @errorName(err) },
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
    groups: []const PackageGroup,
) !void {
    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeCandidatesJson(&payload.writer, groups, true);
        try output.writeFrame(context, payload.writer.buffered());
        return;
    }
    if (invocation.globals.json) {
        try writeCandidatesJson(context.stdout, groups, false);
        try context.stdout.writeByte('\n');
        return;
    }

    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    for (groups) |group| {
        const heading = try std.fmt.allocPrint(
            allocator,
            "Available downgrade options for: {s}",
            .{group.name},
        );
        try output.writeSuccess(context, heading);

        const rows = try allocator.alloc([]const []const u8, group.candidates.len);
        for (rows, 0..) |*cells, index| {
            const candidate = group.candidates[group.candidates.len - 1 - index];
            const values = try allocator.alloc([]const u8, 3);
            values[0] = candidate.filename;
            values[1] = locationName(candidate);
            values[2] = if (candidate.is_installed) "True" else "False";
            cells.* = values;
        }
        try table.write(
            context,
            &.{ "Filename", "Location", "Installed" },
            rows,
        );
    }
}

fn writeCandidatesJson(
    writer: *std.Io.Writer,
    groups: []const PackageGroup,
    ui_mode: bool,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (groups) |group| {
        var remaining = group.candidates.len;
        while (remaining > 0) {
            remaining -= 1;
            const candidate = group.candidates[remaining];
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
    }
    try json.endArray();
}

fn locationName(candidate: DowngradeCandidate) []const u8 {
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
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Unused = struct {
        fn discover(_: @This(), _: *runtime.RuntimeContext, _: *PackageManager.OperationContext, _: []const u8) !CandidateSet {
            return error.ShouldNotRun;
        }

        fn install(_: @This(), _: *runtime.RuntimeContext, _: *PackageManager.OperationContext, _: []const *const PackageManager.Manager.DowngradeCandidate) !void {
            return error.ShouldNotRun;
        }

        fn ignore(_: @This(), _: *runtime.RuntimeContext, _: *PackageManager.OperationContext, _: []const []const u8) !void {
            return error.ShouldNotRun;
        }
    };

    // The catalog requires at least one package, so the parser rejects a bare
    // downgrade before the command runs.
    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{"downgrade"});
    try std.testing.expect(outcome == .failure);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.message, "requires 'packages'") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "downgrade", "  " });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &outcome.dispatch, Unused{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Specify at least one package name") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--target", "1.0-1", "--oldest", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &outcome.dispatch, Unused{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Cannot combine --target with --oldest") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--target", "1.0-1", "--list-options", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &outcome.dispatch, Unused{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Cannot combine --target with --list-options") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--target", "1.0-1", "demo", "libdemo",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &outcome.dispatch, Unused{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Cannot combine --target with multiple packages") != null);

    // A repeated single package is deduplicated, so --target stays usable.
    tc.stdout.writer.end = 0;
    var demo_candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "3.0", "1", "3.0-1", "x86_64", "demo-3.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-3.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "2.0", "4", "2.0-4", "x86_64", "demo-2.0-4-x86_64.pkg.tar.zst", "/cache/demo-2.0-4-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var capture: TestRunner = .{ .groups = &.{.{ .name = "demo", .candidates = &demo_candidates }} };
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--target", "2.0-4", "--no-confirm", "demo", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 1), capture.discover_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.installed_count);
    try std.testing.expectEqualStrings("demo-2.0-4-x86_64.pkg.tar.zst", capture.installed_filenames[0]);
}

test "downgrade lists candidates as C sharp compatible JSON and UI records" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "2.0", "1", "2.0-1", "x86_64", "demo-2.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-2.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "1.0", "2", "1.0-2", "x86_64", "demo-1.0-2-x86_64.pkg.tar.zst", "/var/cache/pacman/pkg/demo-1.0-2-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var capture: TestRunner = .{ .candidates = &candidates };

    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "--json", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    const json_output = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"Location\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"Location\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"Uri\":null") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json_output, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, json_output, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "--ui-mode", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "[JSON]") != null);
    const decoded = try decodeFirstFrame(tc.arena.allocator(), tc.stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Location\":\"Remote\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Location\":\"Local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Uri\"") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, decoded, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, decoded, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    const plain_output = tc.stdout.writer.buffered();
    try std.testing.expect(
        std.mem.indexOf(u8, plain_output, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, plain_output, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );
}

test "downgrade selects oldest and exact targets and updates IgnorePkg only when requested" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "3.0", "1", "3.0-1", "x86_64", "demo-3.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-3.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "2.0", "4", "2.0-4", "x86_64", "demo-2.0-4-x86_64.pkg.tar.zst", "/cache/demo-2.0-4-x86_64.pkg.tar.zst", .local_cache, false),
        testCandidate("demo", "1.0", "2", "1.0-2", "x86_64", "demo-1.0-2-x86_64.pkg.tar.zst", "https://archive.example/demo-1.0-2-x86_64.pkg.tar.zst", .arch_linux, false),
    };
    var capture: TestRunner = .{ .candidates = &candidates };

    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--oldest", "--ignore", "--no-confirm", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 1), capture.install_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.installed_count);
    try std.testing.expectEqualStrings("demo-1.0-2-x86_64.pkg.tar.zst", capture.installed_filenames[0]);
    try std.testing.expectEqual(@as(usize, 1), capture.ignore_calls);
    try std.testing.expectEqualStrings("demo", capture.ignored_names[0]);

    capture.reset();
    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--target", "2.0-4", "--no-confirm", "demo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqualStrings("demo-2.0-4-x86_64.pkg.tar.zst", capture.installed_filenames[0]);
    try std.testing.expectEqual(@as(usize, 0), capture.ignore_calls);
}

test "interactive downgrade selection and confirmations are honored" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "2.0", "1", "2.0-1", "x86_64", "demo-2.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-2.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "1.0", "1", "1.0-1", "x86_64", "demo-1.0-1-x86_64.pkg.tar.zst", "/cache/demo-1.0-1-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var capture: TestRunner = .{ .candidates = &candidates };
    var stdin = std.Io.Reader.fixed("1\ny\nn\n");
    tc.context.stdin = &stdin;
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "downgrade", "demo" });
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.installed_count);
    try std.testing.expectEqualStrings("demo-1.0-1-x86_64.pkg.tar.zst", capture.installed_filenames[0]);
    try std.testing.expectEqual(@as(usize, 0), capture.ignore_calls);
    const rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Select Package: demo") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered, "demo-1.0-1-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, rendered, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Select [1-2] (2):") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do you want to proceed with the installation?") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Do you want to add demo to IgnorePkg list?") != null);
}

test "downgrade installs multiple packages in one transaction" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var demo_candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "3.0", "1", "3.0-1", "x86_64", "demo-3.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-3.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "2.0", "4", "2.0-4", "x86_64", "demo-2.0-4-x86_64.pkg.tar.zst", "/cache/demo-2.0-4-x86_64.pkg.tar.zst", .local_cache, false),
        testCandidate("demo", "1.0", "2", "1.0-2", "x86_64", "demo-1.0-2-x86_64.pkg.tar.zst", "https://archive.example/demo-1.0-2-x86_64.pkg.tar.zst", .arch_linux, false),
    };
    var lib_candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("libdemo", "9.0", "1", "9.0-1", "x86_64", "libdemo-9.0-1-x86_64.pkg.tar.zst", "https://archive.example/libdemo-9.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("libdemo", "8.0", "3", "8.0-3", "x86_64", "libdemo-8.0-3-x86_64.pkg.tar.zst", "/cache/libdemo-8.0-3-x86_64.pkg.tar.zst", .local_cache, false),
    };
    const groups = [_]TestCandidateGroup{
        .{ .name = "demo", .candidates = &demo_candidates },
        .{ .name = "libdemo", .candidates = &lib_candidates },
    };

    // --oldest selects the oldest candidate of every package and --ignore
    // adds every downgraded package within a single transaction.
    var capture: TestRunner = .{ .groups = &groups };
    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--oldest", "--ignore", "--no-confirm", "demo", "libdemo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 1), capture.install_calls);
    try std.testing.expectEqual(@as(usize, 2), capture.installed_count);
    try std.testing.expect(installedContains(&capture, "demo-1.0-2-x86_64.pkg.tar.zst"));
    try std.testing.expect(installedContains(&capture, "libdemo-8.0-3-x86_64.pkg.tar.zst"));
    try std.testing.expectEqual(@as(usize, 2), capture.ignore_calls);
    try std.testing.expectEqualStrings("demo", capture.ignored_names[0]);
    try std.testing.expectEqualStrings("libdemo", capture.ignored_names[1]);

    // Without --oldest, --no-confirm selects the newest candidate per package
    // and no packages are added to IgnorePkg.
    capture.reset();
    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--no-confirm", "demo", "libdemo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expectEqual(@as(usize, 1), capture.install_calls);
    try std.testing.expect(installedContains(&capture, "demo-3.0-1-x86_64.pkg.tar.zst"));
    try std.testing.expect(installedContains(&capture, "libdemo-9.0-1-x86_64.pkg.tar.zst"));
    try std.testing.expectEqual(@as(usize, 0), capture.ignore_calls);
}

test "downgrade aborts when a requested package cannot be resolved" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var demo_candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "1.0", "1", "1.0-1", "x86_64", "demo-1.0-1-x86_64.pkg.tar.zst", "/cache/demo-1.0-1-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var empty_candidates = [_]PackageManager.Manager.DowngradeCandidate{};
    const groups = [_]TestCandidateGroup{
        .{ .name = "demo", .candidates = &demo_candidates },
        .{ .name = "empty", .candidates = &empty_candidates },
    };

    // A package that is not installed aborts before anything is installed.
    var capture: TestRunner = .{ .groups = &groups };
    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--no-confirm", "demo", "missing",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Could not downgrade missing") != null);
    try std.testing.expectEqual(@as(usize, 0), capture.install_calls);

    // A package without candidates reports the specific package and aborts.
    capture.reset();
    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--no-confirm", "demo", "empty",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    const rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "No older version of empty was found") != null);
    try std.testing.expectEqual(@as(usize, 0), capture.install_calls);
}

test "downgrade lists candidates for multiple packages in every output mode" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    var demo_candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("demo", "2.0", "1", "2.0-1", "x86_64", "demo-2.0-1-x86_64.pkg.tar.zst", "https://archive.example/demo-2.0-1-x86_64.pkg.tar.zst", .arch_linux, true),
        testCandidate("demo", "1.0", "2", "1.0-2", "x86_64", "demo-1.0-2-x86_64.pkg.tar.zst", "/var/cache/pacman/pkg/demo-1.0-2-x86_64.pkg.tar.zst", .local_cache, false),
    };
    var lib_candidates = [_]PackageManager.Manager.DowngradeCandidate{
        testCandidate("libdemo", "8.0", "3", "8.0-3", "x86_64", "libdemo-8.0-3-x86_64.pkg.tar.zst", "/cache/libdemo-8.0-3-x86_64.pkg.tar.zst", .local_cache, false),
    };
    const groups = [_]TestCandidateGroup{
        .{ .name = "demo", .candidates = &demo_candidates },
        .{ .name = "libdemo", .candidates = &lib_candidates },
    };
    var capture: TestRunner = .{ .groups = &groups };

    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "--json", "demo", "libdemo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    const json_output = tc.stdout.writer.buffered();
    const decoded = try std.json.parseFromSlice(std.json.Value, tc.arena.allocator(), json_output, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 3), decoded.value.array.items.len);
    try std.testing.expectEqualStrings("demo", decoded.value.array.items[0].object.get("Name").?.string);
    try std.testing.expectEqualStrings("libdemo", decoded.value.array.items[2].object.get("Name").?.string);
    try std.testing.expect(
        std.mem.indexOf(u8, json_output, "demo-1.0-2-x86_64.pkg.tar.zst").? <
            std.mem.indexOf(u8, json_output, "demo-2.0-1-x86_64.pkg.tar.zst").?,
    );

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "--ui-mode", "demo", "libdemo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    const frame = try decodeFirstFrame(tc.arena.allocator(), tc.stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"Location\":\"Local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"Name\":\"libdemo\"") != null);

    tc.stdout.writer.end = 0;
    capture.reset();
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "downgrade", "--list-options", "demo", "libdemo",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture));
    const plain_output = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain_output, "Available downgrade options for: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_output, "Available downgrade options for: libdemo") != null);
    try std.testing.expectEqual(@as(usize, 0), capture.install_calls);
}

const TestCandidateGroup = struct {
    name: []const u8,
    candidates: []PackageManager.Manager.DowngradeCandidate,
};

const TestRunner = struct {
    candidates: []PackageManager.Manager.DowngradeCandidate = &.{},
    groups: []const TestCandidateGroup = &.{},
    discover_calls: usize = 0,
    install_calls: usize = 0,
    installed_count: usize = 0,
    installed_filenames: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    ignore_calls: usize = 0,
    ignored_names: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },

    fn reset(self: *TestRunner) void {
        self.discover_calls = 0;
        self.install_calls = 0;
        self.installed_count = 0;
        self.ignore_calls = 0;
    }

    fn discover(
        self: *TestRunner,
        _: *runtime.RuntimeContext,
        _: *PackageManager.OperationContext,
        package_name: []const u8,
    ) !CandidateSet {
        self.discover_calls += 1;
        if (self.groups.len == 0) return .{ .candidates = self.candidates };
        for (self.groups) |group| {
            if (std.mem.eql(u8, group.name, package_name))
                return .{ .candidates = group.candidates };
        }
        return DowngradeError.PackageNotInstalled;
    }

    fn install(
        self: *TestRunner,
        _: *runtime.RuntimeContext,
        _: *PackageManager.OperationContext,
        candidates: []const *const PackageManager.Manager.DowngradeCandidate,
    ) !void {
        self.install_calls += 1;
        for (candidates) |candidate| {
            if (self.installed_count < self.installed_filenames.len)
                self.installed_filenames[self.installed_count] = candidate.filename;
            self.installed_count += 1;
        }
    }

    fn ignore(
        self: *TestRunner,
        _: *runtime.RuntimeContext,
        _: *PackageManager.OperationContext,
        package_names: []const []const u8,
    ) !void {
        for (package_names) |package_name| {
            if (self.ignore_calls < self.ignored_names.len)
                self.ignored_names[self.ignore_calls] = package_name;
            self.ignore_calls += 1;
        }
    }
};

fn installedContains(runner: *const TestRunner, filename: []const u8) bool {
    for (runner.installed_filenames[0..runner.installed_count]) |installed| {
        if (std.mem.eql(u8, installed, filename)) return true;
    }
    return false;
}

fn testCandidate(
    name: [:0]const u8,
    version: [:0]const u8,
    release: [:0]const u8,
    version_release: [:0]const u8,
    architecture: [:0]const u8,
    filename: []const u8,
    location: []const u8,
    source: PackageManager.Manager.ArchiveSource,
    is_installed: bool,
) PackageManager.Manager.DowngradeCandidate {
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
