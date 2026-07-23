const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");

const ignore_command_path = "shelly mark ignore";
const hold_command_path = "shelly mark hold";
const explicit_command_path = "shelly mark explicit";
const dependency_command_path = "shelly mark dependency";

const MarkKind = enum {
    ignore,
    hold,
    explicit,
    dependency,

    fn isList(self: MarkKind) bool {
        return self == .ignore or self == .hold;
    }
};

const ListAction = enum { list, add, remove, clear };

const PackageList = struct {
    items: []const []const u8,
    owned: bool = false,

    fn deinit(self: *PackageList, allocator: std.mem.Allocator) void {
        if (self.owned) {
            for (self.items) |item| allocator.free(item);
            allocator.free(self.items);
        }
        self.* = undefined;
    }
};

const Runner = struct {
    data: ?*anyopaque = null,
    list: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        kind: MarkKind,
    ) anyerror!PackageList,
    mutate: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        kind: MarkKind,
        action: ListAction,
        packages: []const []const u8,
    ) anyerror!void,
    reason: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        kind: MarkKind,
        package: []const u8,
    ) anyerror!void,
};

const real_runner: Runner = .{
    .list = listReal,
    .mutate = mutateReal,
    .reason = reasonReal,
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    const kind = kindForPath(invocation.command.path) orelse return null;
    if (validationMessage(invocation, kind)) |message|
        return try reportFailure(context, invocation, message);

    const action = if (kind.isList()) selectedListAction(invocation) else null;
    const mutates = !kind.isList() or action.? != .list;
    if (mutates and !invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate mark: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try runWithRunner(context, invocation, kind, real_runner);
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !?u8 {
    const kind = kindForPath(invocation.command.path) orelse return null;
    if (validationMessage(invocation, kind)) |message|
        return try reportFailure(context, invocation, message);
    return try runWithRunner(context, invocation, kind, runner);
}

fn runWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    kind: MarkKind,
    runner: Runner,
) !u8 {
    if (kind.isList()) {
        const action = selectedListAction(invocation).?;
        if (action == .list) return executeList(context, invocation, kind, runner);
        return executeMutation(context, invocation, kind, action, runner);
    }

    if (!invocation.globals.ui_mode and !invocation.globals.no_confirm and
        !try confirm(context, "Do you want to proceed with the operation?", true))
    {
        try context.stdout.writeAll("Operation Cancelled.\n");
        return 0;
    }
    return executeReason(context, invocation, kind, runner);
}

fn executeList(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    kind: MarkKind,
    runner: Runner,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();
    var packages = runner.list(runner.data, context, &operation_context, kind) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Unable to list {s}: {t}",
            .{ directiveName(kind), err },
        );
        defer context.allocator.free(message);
        return reportFailure(context, invocation, message);
    };
    defer packages.deinit(context.allocator);

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeListJson(&payload.writer, packages.items);
        try output.writeFrame(context, payload.writer.buffered());
        const message = try listSummary(context.allocator, kind, packages.items, false);
        defer context.allocator.free(message);
        try output.writeInfoFrame(context, message);
        try ui_operation.flush(context);
        return 0;
    }

    if (invocation.globals.json) {
        try writeListJson(context.stdout, packages.items);
        try context.stdout.writeByte('\n');
        return 0;
    }

    const message = try listSummary(context.allocator, kind, packages.items, true);
    defer context.allocator.free(message);
    try context.stdout.print("{s}\n", .{message});
    return 0;
}

fn executeMutation(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    kind: MarkKind,
    action: ListAction,
    runner: Runner,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();
    runner.mutate(
        runner.data,
        context,
        &operation_context,
        kind,
        action,
        invocation.positionals,
    ) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Unable to update {s}: {t}",
            .{ directiveName(kind), err },
        );
        defer context.allocator.free(message);
        return reportFailure(context, invocation, message);
    };

    const message = try mutationMessage(context.allocator, kind, action, invocation.positionals);
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode) {
        try output.writeInfoFrame(context, message);
        try ui_operation.flush(context);
    } else {
        try output.writeSuccess(context, message);
    }
    return 0;
}

fn executeReason(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    kind: MarkKind,
    runner: Runner,
) !u8 {
    const package = invocation.positionals[0];
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();

    if (invocation.globals.ui_mode) {
        const opening = try std.fmt.allocPrint(context.allocator, "Marking {s}...", .{package});
        defer context.allocator.free(opening);
        try output.writeAlpmInfoFrame(context, "TransactionStart", opening);
        try ui_operation.flush(context);
    }

    runner.reason(runner.data, context, &operation_context, kind, package) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Marking failed for {s}: {t}",
            .{ package, err },
        );
        defer context.allocator.free(message);
        if (invocation.globals.ui_mode) {
            try output.writeErrorFrame(context, message);
            try output.writeAlpmInfoFrame(context, "TransactionFailed", "Marking failed for the package.");
            try ui_operation.flush(context);
            return 1;
        }
        return reportFailure(context, invocation, message);
    };

    const message = try std.fmt.allocPrint(
        context.allocator,
        "Package {s} marked as {s} successfully!",
        .{ package, if (kind == .explicit) "explicit" else "a dependency" },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(context, "TransactionDone", message);
        try ui_operation.flush(context);
    } else {
        try output.writeSuccess(context, message);
    }
    return 0;
}

fn validationMessage(invocation: *const parser.Invocation, kind: MarkKind) ?[]const u8 {
    if (!kind.isList()) {
        if (invocation.positionals.len == 0 or isBlank(invocation.positionals[0]))
            return "No package specified.";
        return null;
    }

    var selected: usize = 0;
    inline for (.{ "--list", "--add", "--remove", "--clear" }) |name| {
        if (optionEnabled(invocation, name)) selected += 1;
    }
    if (selected != 1)
        return "Choose exactly one of --list, --add, --remove, or --clear.";

    const action = selectedListAction(invocation).?;
    if ((action == .add or action == .remove) and invocation.positionals.len == 0)
        return "No packages specified.";
    if ((action == .list or action == .clear) and invocation.positionals.len != 0)
        return "The --list and --clear operations do not accept package arguments.";
    for (invocation.positionals) |package| {
        if (isBlank(package)) return "Package names cannot be empty.";
        const normalized = std.mem.trim(u8, package, " \t\r\n");
        if (kind == .hold and action == .remove and std.mem.eql(u8, normalized, "shelly"))
            return "Package 'shelly' is protected and cannot be removed from HoldPkg.";
    }
    return null;
}

fn kindForPath(path: []const u8) ?MarkKind {
    if (std.mem.eql(u8, path, ignore_command_path)) return .ignore;
    if (std.mem.eql(u8, path, hold_command_path)) return .hold;
    if (std.mem.eql(u8, path, explicit_command_path)) return .explicit;
    if (std.mem.eql(u8, path, dependency_command_path)) return .dependency;
    return null;
}

fn selectedListAction(invocation: *const parser.Invocation) ?ListAction {
    if (optionEnabled(invocation, "--list")) return .list;
    if (optionEnabled(invocation, "--add")) return .add;
    if (optionEnabled(invocation, "--remove")) return .remove;
    if (optionEnabled(invocation, "--clear")) return .clear;
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

fn isBlank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn directiveName(kind: MarkKind) []const u8 {
    return if (kind == .ignore) "IgnorePkg" else "HoldPkg";
}

fn listSummary(
    allocator: std.mem.Allocator,
    kind: MarkKind,
    packages: []const []const u8,
    include_names: bool,
) ![]const u8 {
    if (packages.len == 0)
        return std.fmt.allocPrint(allocator, "{s} list is empty.", .{directiveName(kind)});
    if (!include_names)
        return std.fmt.allocPrint(
            allocator,
            "Total: {d} {s} packages",
            .{ packages.len, if (kind == .ignore) "ignored" else "held" },
        );
    const names = try std.mem.join(allocator, ", ", packages);
    defer allocator.free(names);
    return std.fmt.allocPrint(
        allocator,
        "Total: {d} {s} packages: {s}",
        .{ packages.len, if (kind == .ignore) "ignored" else "held", names },
    );
}

fn mutationMessage(
    allocator: std.mem.Allocator,
    kind: MarkKind,
    action: ListAction,
    packages: []const []const u8,
) ![]const u8 {
    if (action == .clear) {
        if (kind == .hold)
            return allocator.dupe(u8, "Cleared held packages; retained protected package: shelly.");
        return allocator.dupe(u8, "Cleared ignored packages.");
    }
    const names = try std.mem.join(allocator, ", ", packages);
    defer allocator.free(names);
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s}: {s}",
        .{
            if (action == .add) "Added" else "Removed",
            if (action == .add) "to" else "from",
            directiveName(kind),
            names,
        },
    );
}

fn writeListJson(writer: *std.Io.Writer, packages: []const []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (packages) |package| try json.write(package);
    try json.endArray();
}

fn reportFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
        try ui_operation.flush(context);
    } else if (invocation.globals.json) {
        try context.stderr.print("{s}\n", .{message});
    } else {
        try output.writeFailure(context, message);
    }
    return 1;
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

fn listReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    kind: MarkKind,
) !PackageList {
    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        null,
        false,
        null,
    );
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    var native = if (kind == .ignore)
        try manager.get_ignored_packages()
    else
        try manager.get_held_packages();
    defer native.deinit(context.allocator);

    var packages: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (packages.items) |package| context.allocator.free(package);
        packages.deinit(context.allocator);
    }
    for (native.items) |package|
        try packages.append(context.allocator, try context.allocator.dupe(u8, package));
    return .{ .items = try packages.toOwnedSlice(context.allocator), .owned = true };
}

fn mutateReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    kind: MarkKind,
    action: ListAction,
    packages: []const []const u8,
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

    if (action == .add) {
        if (kind == .ignore)
            try manager.ignore_packages(packages)
        else
            try manager.hold_packages(packages);
        return;
    }
    if (action == .remove) {
        if (kind == .ignore)
            try manager.unignore_packages(packages)
        else
            try manager.unhold_packages(packages);
        return;
    }

    var native = if (kind == .ignore)
        try manager.get_ignored_packages()
    else
        try manager.get_held_packages();
    defer native.deinit(context.allocator);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(context.allocator);
    for (native.items) |package| try names.append(context.allocator, package);
    if (kind == .ignore)
        try manager.unignore_packages(names.items)
    else
        try manager.unhold_packages(names.items);
}

fn reasonReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    kind: MarkKind,
    package: []const u8,
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
    const package_z = try context.allocator.dupeZ(u8, package);
    defer context.allocator.free(package_z);
    try manager.update_package_reason(
        package_z,
        if (kind == .explicit) .Explicit else .Dependency,
    );
}

test "mark parses native subcommands and shortcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const ignore = try parser.parse(arena.allocator(), &manifest, &.{
        "mark", "ignore", "--add", "linux", "mesa",
    });
    try std.testing.expect(ignore == .dispatch);
    try std.testing.expectEqualStrings(ignore_command_path, ignore.dispatch.command.path);
    try std.testing.expectEqual(@as(usize, 2), ignore.dispatch.positionals.len);

    const hold = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "hold", "-l" });
    try std.testing.expectEqualStrings(hold_command_path, hold.dispatch.command.path);

    const help_translation = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{"-Mh"},
    );
    try std.testing.expect(help_translation == .translated);
    try std.testing.expectEqual(@as(usize, 2), help_translation.translated.len);
    try std.testing.expectEqualStrings("mark", help_translation.translated[0]);
    try std.testing.expectEqualStrings("--help", help_translation.translated[1]);
    const mark_help = try parser.parse(arena.allocator(), &manifest, help_translation.translated);
    try std.testing.expect(mark_help == .help);
    try std.testing.expectEqualStrings("shelly mark", mark_help.help.path);

    const hold_translation = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{"-Mol"},
    );
    try std.testing.expect(hold_translation == .translated);
    const expected_hold = [_][]const u8{ "mark", "hold", "-l" };
    try std.testing.expectEqual(expected_hold.len, hold_translation.translated.len);
    for (expected_hold, hold_translation.translated) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);

    const explicit_translation = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{ "-Me", "linux" },
    );
    try std.testing.expect(explicit_translation == .translated);
    const expected_explicit = [_][]const u8{ "mark", "explicit", "linux" };
    try std.testing.expectEqual(expected_explicit.len, explicit_translation.translated.len);
    for (expected_explicit, explicit_translation.translated) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);

    const ignore_translation = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{ "-Mga", "linux" },
    );
    const expected_ignore = [_][]const u8{ "mark", "ignore", "-a", "linux" };
    try std.testing.expectEqual(expected_ignore.len, ignore_translation.translated.len);
    for (expected_ignore, ignore_translation.translated) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
}

test "mark validates list operations before running a backend" {
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

    const missing_action = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "ignore", "linux" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&context, &missing_action.dispatch, test_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Choose exactly one") != null);

    stdout.writer.end = 0;
    const missing_packages = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "hold", "--add" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&context, &missing_packages.dispatch, test_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "No packages specified") != null);

    stdout.writer.end = 0;
    const protected = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "hold", "--remove", "shelly" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&context, &protected.dispatch, test_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "is protected") != null);
}

test "mark lists IgnorePkg in plain JSON and UI output" {
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

    const plain = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "ignore", "--list" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &plain.dispatch, test_runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Total: 2 ignored packages: linux, mesa") != null);

    stdout.writer.end = 0;
    const json = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "ignore", "--list", "--json" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &json.dispatch, test_runner));
    try std.testing.expectEqualStrings("[\"linux\",\"mesa\"]\n", stdout.writer.buffered());

    stdout.writer.end = 0;
    const ui = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "ignore", "--list", "--ui-mode" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &ui.dispatch, test_runner));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stdout.writer.buffered(), "[JSON]"));
}

test "mark applies list mutations and confirms install reason changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var stdin = std.Io.Reader.fixed("n\n");
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var capture: TestCapture = .{};
    const runner = capture.runner();

    const add = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "hold", "--add", "linux" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &add.dispatch, runner));
    try std.testing.expectEqual(MarkKind.hold, capture.kind.?);
    try std.testing.expectEqual(ListAction.add, capture.action.?);

    const declined = try parser.parse(arena.allocator(), &manifest, &.{ "mark", "explicit", "linux" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &declined.dispatch, runner));
    try std.testing.expectEqual(@as(usize, 0), capture.reason_calls);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Operation Cancelled") != null);

    const dependency = try parser.parse(arena.allocator(), &manifest, &.{
        "mark", "dependency", "linux", "--no-confirm",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &dependency.dispatch, runner));
    try std.testing.expectEqual(@as(usize, 1), capture.reason_calls);
    try std.testing.expectEqual(MarkKind.dependency, capture.kind.?);
}

const test_runner: Runner = .{
    .list = struct {
        fn call(
            _: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: MarkKind,
        ) !PackageList {
            return .{ .items = &.{ "linux", "mesa" } };
        }
    }.call,
    .mutate = struct {
        fn call(
            _: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: MarkKind,
            _: ListAction,
            _: []const []const u8,
        ) !void {}
    }.call,
    .reason = struct {
        fn call(
            _: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: MarkKind,
            _: []const u8,
        ) !void {}
    }.call,
};

const TestCapture = struct {
    kind: ?MarkKind = null,
    action: ?ListAction = null,
    reason_calls: usize = 0,

    fn runner(self: *TestCapture) Runner {
        return .{
            .data = self,
            .list = list,
            .mutate = mutate,
            .reason = reason,
        };
    }

    fn list(
        _: ?*anyopaque,
        _: *runtime.RuntimeContext,
        _: *Zigalpm.OperationContext,
        _: MarkKind,
    ) !PackageList {
        return .{ .items = &.{} };
    }

    fn mutate(
        data: ?*anyopaque,
        _: *runtime.RuntimeContext,
        _: *Zigalpm.OperationContext,
        kind: MarkKind,
        action: ListAction,
        _: []const []const u8,
    ) !void {
        const self: *TestCapture = @ptrCast(@alignCast(data.?));
        self.kind = kind;
        self.action = action;
    }

    fn reason(
        data: ?*anyopaque,
        _: *runtime.RuntimeContext,
        _: *Zigalpm.OperationContext,
        kind: MarkKind,
        _: []const u8,
    ) !void {
        const self: *TestCapture = @ptrCast(@alignCast(data.?));
        self.kind = kind;
        self.reason_calls += 1;
    }
};
