const std = @import("std");
const test_support = @import("test_support.zig");
const completions = @import("../cli/completions.zig");
const documentation = @import("../cli/documentation.zig");
const output = @import("../output/config.zig");
const pacfiles = @import("pacfiles.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const repository = @import("repository.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");

const command_path = "shelly utility utility";
const default_database_directory = "/var/lib/pacman";

const Operation = union(enum) {
    fix_permissions,
    repair_db,
    docs,
    completions: completions.Shell,
    pacfiles,
};

const Selection = union(enum) {
    operation: Operation,
    missing,
    conflicting,
};

const Real = struct {
    fn run(
        _: @This(),
        context: *runtime.RuntimeContext,
        user: []const u8,
        path: []const u8,
    ) !u8 {
        return runChown(context, user, path);
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (try repository.dispatch(context, invocation)) |exit_code| return exit_code;
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;

    const selection = selectOperation(invocation);
    if (selection != .operation) return try writeSelectionError(context, selection);
    const operation = selection.operation;

    const needs_elevation = operation == .fix_permissions or operation == .repair_db or
        (operation == .pacfiles and pacfiles.requiresElevation(invocation));
    if (needs_elevation and !elevation.isRoot()) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate utility operation: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try execute(context, invocation, operation, Real{});
}

fn execute(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    operation: Operation,
    permission_runner: anytype,
) anyerror!u8 {
    return switch (operation) {
        .fix_permissions => fixPermissions(context, invocation, permission_runner),
        .repair_db => repairDb(context, invocation, default_database_directory),
        .docs => generateDocs(context),
        .completions => |shell| generateCompletions(context, shell),
        .pacfiles => pacfiles.run(context, invocation),
    };
}

fn generateDocs(context: *runtime.RuntimeContext) !u8 {
    const manifest = try spec.Manifest.load(context.allocator);
    try documentation.render(context.allocator, &manifest, context.stdout);
    return 0;
}

fn generateCompletions(context: *runtime.RuntimeContext, shell: completions.Shell) !u8 {
    const manifest = try spec.Manifest.load(context.allocator);
    try completions.render(&manifest, shell, context.stdout);
    return 0;
}

fn selectOperation(invocation: *const parser.Invocation) Selection {
    var selected: ?Operation = null;
    for (invocation.options) |option| {
        const operation: ?Operation = if (std.mem.eql(u8, option.name, "--fix-permissions"))
            .fix_permissions
        else if (std.mem.eql(u8, option.name, "--repair-db"))
            .repair_db
        else if (std.mem.eql(u8, option.name, "--docs"))
            .docs
        else if (std.mem.eql(u8, option.name, "--completions"))
            if (option.value) |value|
                if (completions.Shell.parse(value)) |shell| .{ .completions = shell } else null
            else
                null
        else if (std.mem.eql(u8, option.name, "--pacfiles"))
            .pacfiles
        else if (isPacfileOption(option.name))
            .pacfiles
        else
            null;
        if (operation) |value| {
            if (selected) |current| {
                if (current == .pacfiles and value == .pacfiles) continue;
                return .conflicting;
            }
            selected = value;
        }
    }
    return if (selected) |operation| .{ .operation = operation } else .missing;
}

fn isPacfileOption(name: []const u8) bool {
    return std.mem.eql(u8, name, "--find") or
        std.mem.eql(u8, name, "--locate") or
        std.mem.eql(u8, name, "--pacmandb") or
        std.mem.eql(u8, name, "--backup") or
        std.mem.eql(u8, name, "--cachedir") or
        std.mem.eql(u8, name, "--output") or
        std.mem.eql(u8, name, "--sudo") or
        std.mem.eql(u8, name, "--threeway") or
        std.mem.eql(u8, name, "--nocolor") or
        std.mem.eql(u8, name, "--search-path") or
        std.mem.eql(u8, name, "--diff-program") or
        std.mem.eql(u8, name, "--merge-program");
}

fn writeSelectionError(context: *runtime.RuntimeContext, selection: Selection) !u8 {
    const message = switch (selection) {
        .missing => "No utility operation selected. Use --fix-permissions, --repair-db, --docs, --completions <shell>, or --pacfiles.",
        .conflicting => "Utility operations are mutually exclusive; select exactly one.",
        .operation => unreachable,
    };
    try context.stderr.print("{s}\n", .{message});
    return 1;
}

fn fixPermissions(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    const user = try invokingUser(context) orelse {
        const message = "Could not determine the invoking user (SUDO_USER, DOAS_USER, or PKEXEC_UID).";
        try writeResponseMessage(context, invocation, false, message);
        return 1;
    };

    const paths = [_][]const u8{
        try std.fs.path.join(context.allocator, &.{ try xdg.configHome(context), "shelly" }),
        try xdg.shellyCache(context, &.{}),
        try xdg.shellyData(context, &.{}),
    };
    var found = false;
    var failed = false;
    for (paths) |path| {
        std.Io.Dir.accessAbsolute(context.io, path, .{}) catch continue;
        found = true;
        const exit_code = runner.run(context, user, path) catch |err| {
            failed = true;
            const message = try std.fmt.allocPrint(context.allocator, "Failed to fix ownership for {s}: {t}", .{ path, err });
            try writeResponseMessage(context, invocation, false, message);
            continue;
        };
        if (exit_code == 0) {
            const message = try std.fmt.allocPrint(context.allocator, "Fixed ownership: {s}", .{path});
            try writeResponseMessage(context, invocation, true, message);
        } else {
            failed = true;
            const message = try std.fmt.allocPrint(
                context.allocator,
                "Failed to fix ownership for {s}: chown exited with code {d}",
                .{ path, exit_code },
            );
            try writeResponseMessage(context, invocation, false, message);
        }
    }

    if (!found) {
        try writeResponseMessage(context, invocation, true, "No Shelly directories need permission repair.");
    }
    return if (failed) 1 else 0;
}

fn repairDb(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    database_directory: []const u8,
) !u8 {
    const db_lock = try std.fs.path.join(context.allocator, &.{ database_directory, "db.lck" });
    std.Io.Dir.accessAbsolute(context.io, db_lock, .{}) catch {
        try writeResponseMessage(context, invocation, true, "Database lock is not present; nothing to repair.");
        return 0;
    };
    std.Io.Dir.deleteFileAbsolute(context.io, db_lock) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Failed to remove the package database lock: {t}", .{err});
        try writeResponseMessage(context, invocation, false, message);
        return 1;
    };
    try writeResponseMessage(context, invocation, true, "Removed stale database lock.");
    return 0;
}

fn writeResponseMessage(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    succeeded: bool,
    message: []const u8,
) !void {
    if (invocation.globals.ui_mode) {
        if (succeeded)
            try output.writeInfoFrame(context, message)
        else
            try output.writeErrorFrame(context, message);
    } else if (succeeded) {
        try context.stdout.print("{s}\n", .{message});
    } else {
        try context.stderr.print("{s}\n", .{message});
    }
}

fn runChown(
    context: *runtime.RuntimeContext,
    user: []const u8,
    path: []const u8,
) !u8 {
    const owner = try std.fmt.allocPrint(context.allocator, "{s}:", .{user});
    var child = try std.process.spawn(context.io, .{
        .argv = &.{ "chown", "-R", "--", owner, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(context.io);
    return switch (try child.wait(context.io)) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @intFromEnum(signal)),
        .stopped, .unknown => 1,
    };
}

fn invokingUser(context: *const runtime.RuntimeContext) !?[]const u8 {
    const environment = context.environment orelse return null;
    if (environment.get("SUDO_USER")) |user| {
        if (validInvokingUser(user)) return user;
    }
    if (environment.get("DOAS_USER")) |user| {
        if (validInvokingUser(user)) return user;
    }
    const uid = environment.get("PKEXEC_UID") orelse return null;
    if (uid.len == 0) return null;
    return try usernameForUid(context, uid);
}

fn validInvokingUser(user: []const u8) bool {
    return user.len > 0 and !std.mem.eql(u8, user, "root");
}

fn usernameForUid(context: *const runtime.RuntimeContext, wanted_uid: []const u8) !?[]const u8 {
    const passwd = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        "/etc/passwd",
        context.allocator,
        .limited(1024 * 1024),
    ) catch return null;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const username = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid = fields.next() orelse continue;
        if (std.mem.eql(u8, uid, wanted_uid) and validInvokingUser(username))
            return username;
    }
    return null;
}

fn parseInvocation(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) !parser.Invocation {
    const manifest = try spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, arguments);
    try std.testing.expect(outcome == .dispatch);
    return outcome.dispatch;
}

test "utility long forms and -T modifiers select each operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const shortcodes = @import("../cli/shortcodes.zig");

    for ([_]struct {
        shortcode: []const []const u8,
        expected: []const []const u8,
        option_name: []const u8,
        value: ?[]const u8 = null,
    }{
        .{ .shortcode = &.{"-Tf"}, .expected = &.{ "utility", "-f" }, .option_name = "--fix-permissions" },
        .{ .shortcode = &.{"-Td"}, .expected = &.{ "utility", "-d" }, .option_name = "--docs" },
        .{ .shortcode = &.{ "-Tc", "fish" }, .expected = &.{ "utility", "-c", "fish" }, .option_name = "--completions", .value = "fish" },
        .{ .shortcode = &.{"-Tp"}, .expected = &.{ "utility", "-p" }, .option_name = "--pacfiles" },
    }) |expected| {
        const translation = try shortcodes.translate(arena.allocator(), &manifest, expected.shortcode);
        try std.testing.expect(translation == .translated);
        try expectArguments(expected.expected, translation.translated);
        const parsed = try parser.parse(arena.allocator(), &manifest, translation.translated);
        try std.testing.expect(parsed == .dispatch);
        try std.testing.expectEqualStrings(command_path, parsed.dispatch.command.path);
        try std.testing.expectEqualStrings(expected.option_name, parsed.dispatch.options[0].name);
        if (expected.value) |value| try std.testing.expectEqualStrings(value, parsed.dispatch.options[0].value.?);
    }

    const long_form = try parser.parse(arena.allocator(), &manifest, &.{ "utility", "--docs" });
    try std.testing.expect(long_form == .dispatch);
    try std.testing.expect(selectOperation(&long_form.dispatch) == .operation);

    const help = try shortcodes.translate(arena.allocator(), &manifest, &.{"-Th"});
    try expectArguments(&.{ "utility", "--help" }, help.translated);

    const pacdiff_output = try shortcodes.translate(arena.allocator(), &manifest, &.{"-To"});
    try expectArguments(&.{ "utility", "-o" }, pacdiff_output.translated);
    const parsed_pacdiff = try parser.parse(arena.allocator(), &manifest, pacdiff_output.translated);
    try std.testing.expect(parsed_pacdiff == .dispatch);
    try std.testing.expect(selectOperation(&parsed_pacdiff.dispatch) == .operation);
    try std.testing.expect(parsed_pacdiff.dispatch.options[0].name.len > 0);
}

test "upgrade retains -U and update migrates to -E" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const shortcodes = @import("../cli/shortcodes.zig");

    const upgrade = try shortcodes.translate(arena.allocator(), &manifest, &.{"-U"});
    try expectArguments(&.{ "upgrade", "all" }, upgrade.translated);
    const update = try shortcodes.translate(arena.allocator(), &manifest, &.{ "-Ef", "org.example.App" });
    try expectArguments(&.{ "update", "flatpak", "org.example.App" }, update.translated);
}

test "utility rejects missing and conflicting operations" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    const missing = try parseInvocation(tc.arena.allocator(), &.{"utility"});
    try std.testing.expectEqual(@as(u8, 1), try writeSelectionError(&tc.context, selectOperation(&missing)));
    try std.testing.expect(std.mem.indexOf(u8, tc.stderr.writer.buffered(), "No utility operation selected") != null);

    const conflicting = try parseInvocation(tc.arena.allocator(), &.{ "utility", "--docs", "--fix-permissions" });
    try std.testing.expect(selectOperation(&conflicting) == .conflicting);

    const pacfile_conflict = try parseInvocation(tc.arena.allocator(), &.{ "utility", "--docs", "--find" });
    try std.testing.expect(selectOperation(&pacfile_conflict) == .conflicting);
}

test "docs and completion operations write generated output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    try std.testing.expectEqual(@as(u8, 0), try generateDocs(&tc.context));
    try std.testing.expect(std.mem.startsWith(u8, tc.stdout.writer.buffered(), "# Shelly CLI Documentation"));
    tc.stdout.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try generateCompletions(&tc.context, .bash));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "complete -F _shelly shelly") != null);
}

test "permission repair targets only existing Shelly user directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var anchor: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-utility-test-{x}", .{@intFromPtr(&anchor)});
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const config_root = try std.fs.path.join(allocator, &.{ root, "config" });
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    const data_root = try std.fs.path.join(allocator, &.{ root, "data" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try std.fs.path.join(allocator, &.{ config_root, "shelly" }));
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try std.fs.path.join(allocator, &.{ cache_root, "Shelly" }));

    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("SUDO_USER", "tester");
    try environment.put("XDG_CONFIG_HOME", config_root);
    try environment.put("XDG_CACHE_HOME", cache_root);
    try environment.put("XDG_DATA_HOME", data_root);
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
    const invocation = try parseInvocation(allocator, &.{ "utility", "--fix-permissions" });

    const Capture = struct {
        calls: usize = 0,
        fn run(self: *@This(), _: *runtime.RuntimeContext, user: []const u8, path: []const u8) !u8 {
            try std.testing.expectEqualStrings("tester", user);
            if (self.calls == 0)
                try std.testing.expect(std.mem.endsWith(u8, path, "/config/shelly"))
            else
                try std.testing.expect(std.mem.endsWith(u8, path, "/cache/Shelly"));
            self.calls += 1;
            return 0;
        }
    };
    var capture: Capture = .{};
    try std.testing.expectEqual(@as(u8, 0), try fixPermissions(
        &context,
        &invocation,
        &capture,
    ));
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stdout.writer.buffered(), "Fixed ownership:"));
}

test "selectOperation selects repair-db from flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invocation = try parseInvocation(arena.allocator(), &.{ "utility", "--repair-db" });
    const selection = selectOperation(&invocation);
    try std.testing.expect(selection == .operation);
    try std.testing.expect(selection.operation == .repair_db);
}

test "repairDb removes stale pacman database lock" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const allocator = tc.arena.allocator();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const database_directory = absolute_buffer[0..absolute_length];
    const db_lock = try std.fs.path.join(allocator, &.{ database_directory, "db.lck" });
    var file = try std.Io.Dir.createFileAbsolute(std.testing.io, db_lock, .{});
    file.close(std.testing.io);

    const invocation = try parseInvocation(allocator, &.{ "utility", "--repair-db" });

    try std.testing.expectEqual(@as(u8, 0), try repairDb(&tc.context, &invocation, database_directory));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Removed stale database lock") != null);

    const access_err = std.Io.Dir.accessAbsolute(std.testing.io, db_lock, .{}) catch |err| err;
    try std.testing.expect(access_err == error.FileNotFound);
}

test "repairDb succeeds gracefully when no lock file is present" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const allocator = tc.arena.allocator();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const database_directory = absolute_buffer[0..absolute_length];

    const invocation = try parseInvocation(allocator, &.{ "utility", "--repair-db" });

    try std.testing.expectEqual(@as(u8, 0), try repairDb(&tc.context, &invocation, database_directory));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "not present") != null);
}

fn expectArguments(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, value| try std.testing.expectEqualStrings(wanted, value);
}
