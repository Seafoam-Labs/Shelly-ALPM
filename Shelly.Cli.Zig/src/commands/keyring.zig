const std = @import("std");
const output = @import("../output/config.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");

const command_prefix = "shelly keyring ";

const Action = enum {
    init,
    list,
    refresh,
    lsign,
    populate,
    recv,
};

const RunOutcome = struct {
    exit_code: u8,
    failed_key: ?[]const u8 = null,
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        arguments: []const []const u8,
    ) anyerror!u8,
};

const real_runner: Runner = .{ .call = runPacmanKey };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (actionForPath(invocation.command.path) == null) return null;

    if (!invocation.globals.ui_mode and !elevation.isRoot()) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate keyring operation: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(context, invocation, real_runner);
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    const action = actionForPath(invocation.command.path) orelse return 1;
    const opening = try openingMessage(context.allocator, action, invocation.positionals);
    defer context.allocator.free(opening);
    try writeOpening(context, invocation, opening);
    try flush(context);

    const result = runAction(context, invocation, action, runner) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Failed to run pacman-key: {t}",
            .{err},
        );
        defer context.allocator.free(message);
        try writeFailure(context, invocation, message, failureMessage(action));
        try flush(context);
        return 1;
    };

    if (result.exit_code == 0) {
        try writeCompletion(context, invocation, action, true);
        try flush(context);
        return 0;
    }

    if (result.failed_key) |key| {
        const message = try std.fmt.allocPrint(context.allocator, "Failed to sign key: {s}", .{key});
        defer context.allocator.free(message);
        if (!invocation.globals.ui_mode) try output.writeFailure(context, message);
    }
    try writeCompletion(context, invocation, action, false);
    try flush(context);
    return result.exit_code;
}

fn runAction(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    action: Action,
    runner: Runner,
) !RunOutcome {
    switch (action) {
        .init => return .{ .exit_code = try runner.call(runner.data, context, &.{ "pacman-key", "--init" }) },
        .list => return .{ .exit_code = try runner.call(runner.data, context, &.{ "pacman-key", "--list-keys" }) },
        .refresh => return .{ .exit_code = try runner.call(runner.data, context, &.{ "pacman-key", "--refresh-keys" }) },
        .lsign => {
            for (invocation.positionals) |key| {
                const exit_code = try runner.call(
                    runner.data,
                    context,
                    &.{ "pacman-key", "--lsign-key", key },
                );
                if (exit_code != 0) return .{ .exit_code = exit_code, .failed_key = key };
            }
            return .{ .exit_code = 0 };
        },
        .populate => {
            const arguments = try context.allocator.alloc([]const u8, invocation.positionals.len + 2);
            defer context.allocator.free(arguments);
            arguments[0] = "pacman-key";
            arguments[1] = "--populate";
            @memcpy(arguments[2..], invocation.positionals);
            return .{ .exit_code = try runner.call(runner.data, context, arguments) };
        },
        .recv => {
            const keyserver = optionValue(invocation, "--keyserver");
            const arguments = try context.allocator.alloc(
                []const u8,
                invocation.positionals.len + 2 + @as(usize, if (keyserver == null) 0 else 2),
            );
            defer context.allocator.free(arguments);
            arguments[0] = "pacman-key";
            arguments[1] = "--recv-keys";
            @memcpy(arguments[2 .. invocation.positionals.len + 2], invocation.positionals);
            if (keyserver) |server| {
                arguments[invocation.positionals.len + 2] = "--keyserver";
                arguments[invocation.positionals.len + 3] = server;
            }
            return .{ .exit_code = try runner.call(runner.data, context, arguments) };
        },
    }
}

fn runPacmanKey(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    arguments: []const []const u8,
) !u8 {
    try flush(context);
    var child = try std.process.spawn(context.io, .{
        .argv = arguments,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(context.io);
    return exitCode(try child.wait(context.io));
}

fn writeOpening(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !void {
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(context, "TransactionStart", message);
    } else if (output.supportsAnsi(context)) {
        try context.stdout.print("\x1b[38;2;255;255;0m{s}\x1b[0m\n", .{message});
    } else {
        try context.stdout.print("{s}\n", .{message});
    }
}

fn writeFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    plain_message: []const u8,
    ui_message: []const u8,
) !void {
    if (invocation.globals.ui_mode)
        try output.writeAlpmInfoFrame(context, "TransactionFailed", ui_message)
    else
        try output.writeFailure(context, plain_message);
}

fn writeCompletion(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    action: Action,
    succeeded: bool,
) !void {
    const message = if (succeeded) successMessage(action) else failureMessage(action);
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(
            context,
            if (succeeded) "TransactionDone" else "TransactionFailed",
            message,
        );
    } else if (action != .list and !(action == .lsign and !succeeded)) {
        if (succeeded)
            try output.writeSuccess(context, message)
        else
            try output.writeFailure(context, message);
    }
}

fn openingMessage(
    allocator: std.mem.Allocator,
    action: Action,
    values: []const []const u8,
) ![]const u8 {
    return switch (action) {
        .init => allocator.dupe(u8, "Initializing pacman keyring..."),
        .list => allocator.dupe(u8, "Listing keys in keyring..."),
        .refresh => allocator.dupe(u8, "Refreshing keys from keyserver..."),
        .lsign => joinedMessage(allocator, "Locally signing keys: ", values),
        .populate => if (values.len == 0)
            allocator.dupe(u8, "Populating keyring with default keys...")
        else
            joinedMessage(allocator, "Populating keyring with: ", values),
        .recv => joinedMessage(allocator, "Receiving keys: ", values),
    };
}

fn joinedMessage(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    values: []const []const u8,
) ![]const u8 {
    const joined = try std.mem.join(allocator, ", ", values);
    defer allocator.free(joined);
    return std.fmt.allocPrint(allocator, "{s}{s}...", .{ prefix, joined });
}

fn successMessage(action: Action) []const u8 {
    return switch (action) {
        .init => "Keyring initialized successfully!",
        .list => "Keys listed.",
        .refresh => "Keys refreshed successfully!",
        .lsign => "Keys signed successfully!",
        .populate => "Keyring populated successfully!",
        .recv => "Keys received successfully!",
    };
}

fn failureMessage(action: Action) []const u8 {
    return switch (action) {
        .init => "Failed to initialize keyring.",
        .list => "Failed to list keys.",
        .refresh => "Failed to refresh keys.",
        .lsign => "Failed to sign keys.",
        .populate => "Failed to populate keyring.",
        .recv => "Failed to receive keys.",
    };
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

fn actionForPath(path: []const u8) ?Action {
    if (!std.mem.startsWith(u8, path, command_prefix)) return null;
    const name = path[command_prefix.len..];
    inline for (std.meta.tags(Action)) |action| {
        if (std.mem.eql(u8, name, @tagName(action))) return action;
    }
    return null;
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @intFromEnum(signal)),
        .stopped, .unknown => 1,
    };
}

fn flush(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

test "keyring catalog exposes top-level actions and recv keyserver help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    inline for (std.meta.tags(Action)) |action| {
        const path = try std.fmt.allocPrint(
            arena.allocator(),
            "shelly keyring {s}",
            .{@tagName(action)},
        );
        try std.testing.expect(manifest.findByPath(path) != null);
    }
    try std.testing.expect(manifest.findByPath("shelly recv keyring") == null);
    const recv = manifest.findByPath("shelly keyring recv").?;
    try std.testing.expectEqualStrings("--keyserver", manifest.findOption(recv, "--keyserver").?.name);

    const missing_action = try parser.parse(arena.allocator(), &manifest, &.{"keyring"});
    try std.testing.expect(missing_action == .failure);
    const missing_key = try parser.parse(arena.allocator(), &manifest, &.{ "keyring", "recv" });
    try std.testing.expect(missing_key == .failure);
}

test "keyring maps every action to structured pacman-key arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const expected_calls = [_][]const []const u8{
        &.{ "pacman-key", "--init" },
        &.{ "pacman-key", "--list-keys" },
        &.{ "pacman-key", "--refresh-keys" },
        &.{ "pacman-key", "--lsign-key", "AAAA" },
        &.{ "pacman-key", "--lsign-key", "BBBB" },
        &.{ "pacman-key", "--populate", "archlinux", "cachyos" },
        &.{ "pacman-key", "--recv-keys", "CCCC", "DDDD", "--keyserver", "hkps://keys.example" },
    };
    const Capture = struct {
        expected: []const []const []const u8,
        index: usize = 0,
    };
    var capture: Capture = .{ .expected = &expected_calls };
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                arguments: []const []const u8,
            ) !u8 {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                try std.testing.expect(observed.index < observed.expected.len);
                const expected = observed.expected[observed.index];
                try std.testing.expectEqual(expected.len, arguments.len);
                for (expected, arguments) |wanted, actual|
                    try std.testing.expectEqualStrings(wanted, actual);
                observed.index += 1;
                return 0;
            }
        }.run,
    };

    for ([_][]const []const u8{
        &.{ "keyring", "init" },
        &.{ "keyring", "list" },
        &.{ "keyring", "refresh" },
        &.{ "keyring", "lsign", "AAAA", "BBBB" },
        &.{ "keyring", "populate", "archlinux", "cachyos" },
        &.{ "keyring", "recv", "CCCC", "DDDD", "--keyserver", "hkps://keys.example" },
    }) |arguments| {
        const outcome = try parser.parse(arena.allocator(), &manifest, arguments);
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
        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    }
    try std.testing.expectEqual(expected_calls.len, capture.index);
}

test "keyring local signing stops at the first failed key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "keyring", "lsign", "AAAA", "BBBB", "CCCC" },
    );
    try std.testing.expect(outcome == .dispatch);

    var calls: usize = 0;
    const runner: Runner = .{
        .data = &calls,
        .call = struct {
            fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, _: []const []const u8) !u8 {
                const count: *usize = @ptrCast(@alignCast(data.?));
                count.* += 1;
                return if (count.* == 2) 9 else 0;
            }
        }.run,
    };
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

    try std.testing.expectEqual(@as(u8, 9), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Failed to sign key: BBBB") != null);
}

test "keyring UI mode emits transaction lifecycle frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "keyring", "populate", "--ui-mode" },
    );
    try std.testing.expect(outcome == .dispatch);

    const runner: Runner = .{ .call = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: []const []const u8) !u8 {
            return 0;
        }
    }.run };
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

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[JSON]") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "[/JSON]"));
}
