const std = @import("std");
const diagnostics = @import("diagnostics");
const PackageManager = @import("PackageManager");
const test_support = @import("test_support.zig");
const output = @import("../output/config.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");

const command_path = "shelly utility repository";

const Action = enum { add, remove, list };

const Real = struct {
    fn keyStatus(_: Real, context: *runtime.RuntimeContext, fingerprint: []const u8) !KeyStatus {
        var arena = std.heap.ArenaAllocator.init(context.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const directory = try context.packageKeyringDirectory(allocator);
        const result = try std.process.run(allocator, context.io, .{
            .argv = &.{ "gpg", "--homedir", directory, "--batch", "--no-tty", "--with-colons", "--list-keys" },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } },
        });
        if (exitCode(result.term) != 0) return error.KeyringLookupFailed;
        return listedKeyStatus(result.stdout, fingerprint);
    }

    fn receive(_: Real, context: *runtime.RuntimeContext, fingerprint: []const u8, ui_mode: bool) !u8 {
        return runShellyKey(context, &.{ "shelly-key", "--recv-keys", fingerprint }, ui_mode);
    }

    fn lsign(
        _: Real,
        context: *runtime.RuntimeContext,
        key: []const u8,
        ui_mode: bool,
    ) !u8 {
        return runShellyKey(context, &.{ "shelly-key", "--lsign-key", key }, ui_mode);
    }

    fn list(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *PackageManager.OperationContext,
    ) !std.ArrayList([]const u8) {
        return listReal(context, operation_context);
    }

    fn mutate(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *PackageManager.OperationContext,
        action: Action,
        name: []const u8,
        url: ?[]const u8,
    ) !void {
        return mutateReal(context, operation_context, action, name, url);
    }

    fn sync(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *PackageManager.OperationContext,
    ) !void {
        return syncReal(context, operation_context);
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;

    if (validationMessage(invocation)) |message|
        return try reportFailure(context, invocation, message);

    const action = selectedAction(invocation).?;
    const mutates = action != .list;
    if (mutates and !invocation.globals.ui_mode and !elevation.isRoot()) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Could not obtain administrator privileges for repository operation. {0s}\n\nTechnical details: {1s}\n", .{ diagnostics.cause(err), @errorName(err) });
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try runWithRunner(context, invocation, action, Real{});
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;

    if (validationMessage(invocation)) |message|
        return try reportFailure(context, invocation, message);
    const action = selectedAction(invocation).?;
    return try runWithRunner(context, invocation, action, runner);
}

fn runWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    action: Action,
    runner: anytype,
) anyerror!u8 {
    return switch (action) {
        .list => executeList(context, invocation, runner),
        .add, .remove => executeMutation(context, invocation, action, runner),
    };
}

fn executeList(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    var operation_context = PackageManager.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();

    var names = runner.list(context, &operation_context) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Could not list repositories: {0s}\n\nTechnical details: {1s}",
            .{ diagnostics.cause(err), @errorName(err) },
        );
        defer context.allocator.free(message);
        return reportFailure(context, invocation, message);
    };
    defer names.deinit(context.allocator);

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeListJson(&payload.writer, names.items);
        try output.writeFrame(context, payload.writer.buffered());
        const summary = try listSummary(context.allocator, names.items, false);
        defer context.allocator.free(summary);
        try output.writeInfoFrame(context, summary);
        try ui_operation.flush(context);
        return 0;
    }

    if (invocation.globals.json) {
        try writeListJson(context.stdout, names.items);
        try context.stdout.writeByte('\n');
        return 0;
    }

    const summary = try listSummary(context.allocator, names.items, true);
    defer context.allocator.free(summary);
    try context.stdout.print("{s}\n", .{summary});
    return 0;
}

fn executeMutation(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    action: Action,
    runner: anytype,
) anyerror!u8 {
    const name = invocation.positionals[0];
    const url: ?[]const u8 = if (invocation.positionals.len > 1) invocation.positionals[1] else null;
    const lsign_key = optionValue(invocation, "--lsign-key");
    const signing_key = optionValue(invocation, "--signing-key");

    var operation_context = PackageManager.OperationContext.init(context.allocator, context.io);
    context.attachTransactionLog(&operation_context);
    defer operation_context.deinit();

    if (invocation.globals.ui_mode) {
        const opening = try openingMessage(context.allocator, action, name);
        defer context.allocator.free(opening);
        try output.writeAlpmInfoFrame(context, "TransactionStart", opening);
        try ui_operation.flush(context);
    }

    // 1) Locally sign the key first, before writing any configuration.
    if (action == .add) {
        if (signing_key) |fingerprint| {
            prepareSigningKey(context, runner, fingerprint, invocation.globals.ui_mode) catch |err| {
                const reason = switch (err) {
                    error.KeyringLookupFailed => "Could not inspect the package-signing keyring.",
                    error.KeyReceiveFailed => "Could not receive the requested key. Check the fingerprint and the configured keyserver.",
                    error.KeyFingerprintMismatch => "The requested primary fingerprint was not found after import. No key was signed.",
                    error.UnusableSigningKey => "The requested key is revoked, expired, disabled, or cannot sign packages.",
                    error.KeySignFailed => "Could not locally sign the requested key.",
                    error.KeyNotTrusted => "The requested key is still not trusted after local signing.",
                };
                const message = try std.fmt.allocPrint(context.allocator, "{s}\n\nFingerprint: {f}\nTechnical details: {t}", .{ reason, diagnostics.safe(fingerprint), err });
                defer context.allocator.free(message);
                return reportFailure(context, invocation, message);
            };
        }
        if (lsign_key) |key| {
            const lsign_code = runner.lsign(context, key, invocation.globals.ui_mode) catch |err| {
                const message = try std.fmt.allocPrint(
                    context.allocator,
                    "Could not locally sign repository key {0f}. {1s} Review the keyring command output before trying again.\n\nTechnical details: {2s}",
                    .{ diagnostics.safe(key), diagnostics.cause(err), @errorName(err) },
                );
                defer context.allocator.free(message);
                return reportFailure(context, invocation, message);
            };
            if (lsign_code != 0) {
                const message = try std.fmt.allocPrint(
                    context.allocator,
                    "Could not locally sign repository key {0f}. Review the keyring command output before trying again.\n\nTechnical details: {1d}",
                    .{ diagnostics.safe(key), lsign_code },
                );
                defer context.allocator.free(message);
                return reportFailure(context, invocation, message);
            }
        }
    }

    // 2) Apply the config mutation with a manager opened as root.
    runner.mutate(context, &operation_context, action, name, url) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "{s}: {t}",
            .{ failureVerb(action), err },
        );
        defer context.allocator.free(message);
        return reportFailure(context, invocation, message);
    };

    // 3) Refresh databases with a FRESH manager so the new repo list is
    //    registered with libalpm (the manager built in step 2 still holds the
    //    old repository set on its handle).
    if (!optionEnabled(invocation, "--no-sync")) {
        runner.sync(context, &operation_context) catch |err| {
            const message = try std.fmt.allocPrint(
                context.allocator,
                "{0f}, but the repository package lists could not be refreshed. {1s}\n\nTechnical details: {2s}",
                .{ diagnostics.safe(successVerbPast(action)), diagnostics.cause(err), @errorName(err) },
            );
            defer context.allocator.free(message);
            if (invocation.globals.ui_mode) {
                try output.writeAlpmInfoFrame(context, "TransactionFailed", message);
                try ui_operation.flush(context);
            } else {
                try output.writeFailure(context, message);
            }
            return 1;
        };
    }

    const message = try successMessage(context.allocator, action, name, optionEnabled(invocation, "--no-sync"));
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(context, "TransactionDone", message);
        try ui_operation.flush(context);
    } else {
        try output.writeSuccess(context, message);
    }
    return 0;
}

const KeyStatus = enum { missing, untrusted, trusted, unusable };
const KeySetupError = error{
    KeyringLookupFailed,
    KeyReceiveFailed,
    KeyFingerprintMismatch,
    UnusableSigningKey,
    KeySignFailed,
    KeyNotTrusted,
};

fn listedKeyStatus(listing: []const u8, fingerprint: []const u8) KeyStatus {
    var primary: ?KeyStatus = null;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const kind = fields.next().?;
        if (std.mem.eql(u8, kind, "pub")) {
            const validity = fields.next() orelse "";
            for (0..9) |_| _ = fields.next();
            const capabilities = fields.next() orelse "";
            primary = if (std.mem.indexOfScalar(u8, capabilities, 'S') == null or
                std.mem.indexOfScalar(u8, capabilities, 'D') != null or
                validity.len != 1 or std.mem.indexOfScalar(u8, "redi", validity[0]) != null)
                .unusable
            else if (std.mem.eql(u8, validity, "f") or std.mem.eql(u8, validity, "u"))
                .trusted
            else
                .untrusted;
        } else if (std.mem.eql(u8, kind, "fpr")) {
            if (primary) |status| {
                for (0..8) |_| _ = fields.next();
                if (std.ascii.eqlIgnoreCase(fields.next() orelse "", fingerprint)) return status;
            }
            primary = null; // Only the primary fingerprint can authorize trust.
        } else if (std.mem.eql(u8, kind, "sub")) {
            primary = null;
        }
    }
    return .missing;
}

fn prepareSigningKey(context: *runtime.RuntimeContext, runner: anytype, fingerprint: []const u8, ui_mode: bool) KeySetupError!void {
    var status = runner.keyStatus(context, fingerprint) catch return error.KeyringLookupFailed;
    if (status == .missing) {
        const code = runner.receive(context, fingerprint, ui_mode) catch return error.KeyReceiveFailed;
        if (code != 0) return error.KeyReceiveFailed;
        status = runner.keyStatus(context, fingerprint) catch return error.KeyringLookupFailed;
    }
    switch (status) {
        .trusted => return,
        .missing => return error.KeyFingerprintMismatch,
        .unusable => return error.UnusableSigningKey,
        .untrusted => {},
    }
    const code = runner.lsign(context, fingerprint, ui_mode) catch return error.KeySignFailed;
    if (code != 0) return error.KeySignFailed;
    const signed = runner.keyStatus(context, fingerprint) catch return error.KeyringLookupFailed;
    if (signed != .trusted) return error.KeyNotTrusted;
}

fn validationMessage(invocation: *const parser.Invocation) ?[]const u8 {
    var selected_count: usize = 0;
    inline for (.{ "--add", "--remove", "--list" }) |name| {
        if (optionEnabled(invocation, name)) selected_count += 1;
    }
    if (selected_count != 1)
        return "Choose exactly one of --add, --remove, or --list.";

    const action = selectedAction(invocation).?;
    if (optionValue(invocation, "--signing-key")) |fingerprint| {
        if (action != .add or optionValue(invocation, "--lsign-key") != null)
            return "--signing-key is only for --add and cannot be combined with --lsign-key.";
        if (fingerprint.len != 40 and fingerprint.len != 64)
            return "--signing-key requires a full OpenPGP fingerprint.";
        for (fingerprint) |digit| {
            if (!std.ascii.isHex(digit)) return "--signing-key requires a full OpenPGP fingerprint.";
        }
    }
    return switch (action) {
        .list => null,
        .add, .remove => blk: {
            if (invocation.positionals.len == 0 or isBlank(invocation.positionals[0]))
                break :blk "Specify the repository name to add or remove.";
            for (invocation.positionals) |positional| {
                if (isBlank(positional)) break :blk "Repository arguments cannot be empty.";
            }
            if (action == .add and (invocation.positionals.len < 2 or isBlank(invocation.positionals[1])))
                break :blk "--add requires a repository name and a server URL.";
            break :blk null;
        },
    };
}

fn selectedAction(invocation: *const parser.Invocation) ?Action {
    if (optionEnabled(invocation, "--add")) return .add;
    if (optionEnabled(invocation, "--remove")) return .remove;
    if (optionEnabled(invocation, "--list")) return .list;
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

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

fn isBlank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn listSummary(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    include_names: bool,
) ![]const u8 {
    if (names.len == 0) return allocator.dupe(u8, "No repositories configured.");
    if (!include_names)
        return std.fmt.allocPrint(allocator, "Total {d} repositories", .{names.len});
    const joined = try std.mem.join(allocator, ", ", names);
    defer allocator.free(joined);
    return std.fmt.allocPrint(allocator, "Total {d} repositories: {s}", .{ names.len, joined });
}

fn openingMessage(
    allocator: std.mem.Allocator,
    action: Action,
    name: []const u8,
) ![]const u8 {
    return switch (action) {
        .add => std.fmt.allocPrint(allocator, "Adding repository {s}...", .{name}),
        .remove => std.fmt.allocPrint(allocator, "Removing repository {s}...", .{name}),
        .list => allocator.dupe(u8, "Listing repositories..."),
    };
}

fn successMessage(
    allocator: std.mem.Allocator,
    action: Action,
    name: []const u8,
    no_sync: bool,
) ![]const u8 {
    const suffix: []const u8 = if (no_sync) "" else " and databases refreshed.";
    return switch (action) {
        .add => std.fmt.allocPrint(allocator, "Repository {s} added{s}", .{ name, suffix }),
        .remove => std.fmt.allocPrint(allocator, "Repository {s} removed{s}", .{ name, suffix }),
        .list => allocator.dupe(u8, "Repositories listed."),
    };
}

fn failureVerb(action: Action) []const u8 {
    return switch (action) {
        .add => "Could not add the selected repository.",
        .remove => "Could not remove the selected repository.",
        .list => "Could not list repositories.",
    };
}

fn successVerbPast(action: Action) []const u8 {
    return switch (action) {
        .add => "Repository added",
        .remove => "Repository removed",
        .list => "Repositories listed",
    };
}

fn writeListJson(writer: *std.Io.Writer, names: []const []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (names) |name| try json.write(name);
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

fn listReal(
    context: *runtime.RuntimeContext,
    operation_context: *PackageManager.OperationContext,
) !std.ArrayList([]const u8) {
    const manager = try PackageManager.Manager.init(
        context.allocator,
        context.environ,
        .{ .config_path = context.config_path, .use_root = false, .operation_context = operation_context },
    );
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);
    return manager.get_repository_names();
}

fn mutateReal(
    context: *runtime.RuntimeContext,
    operation_context: *PackageManager.OperationContext,
    action: Action,
    name: []const u8,
    url: ?[]const u8,
) !void {
    {
        const manager = try PackageManager.Manager.init(
            context.allocator,
            context.environ,
            .{ .config_path = context.config_path, .use_root = true, .operation_context = operation_context },
        );
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);

        switch (action) {
            .add => {
                const server = url orelse return error.MissingRepositoryUrl;
                const servers = [_][]const u8{server};
                try manager.add_repository(name, &servers, "", "");
            },
            .remove => {
                // Detect unknown names up front for a clearer message than the
                // silent no-op that remove_repository performs on its own.
                if (manager.find_configured_repository(name) == null)
                    return error.RepositoryNotConfigured;
                try manager.remove_repository(name);
            },
            .list => unreachable,
        }
    }
}

fn syncReal(
    context: *runtime.RuntimeContext,
    operation_context: *PackageManager.OperationContext,
) !void {
    // A fresh manager is intentionally built here so that libalpm registers the
    // updated repository list before the databases are refreshed.
    const manager = try PackageManager.Manager.init(
        context.allocator,
        context.environ,
        .{ .config_path = context.config_path, .use_root = true, .operation_context = operation_context },
    );
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);
    try manager.sync(true);
}

fn runShellyKey(
    context: *runtime.RuntimeContext,
    arguments: []const []const u8,
    ui_mode: bool,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const key_arguments = try context.keyArguments(arena.allocator(), arguments);
    try context.stdout.flush();
    try context.stderr.flush();
    var child = try std.process.spawn(context.io, .{
        .argv = key_arguments,
        .stdin = .inherit,
        // Keep human-readable keyring output out of the UI's framed stream.
        .stdout = if (ui_mode) .ignore else .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(context.io);
    return exitCode(try child.wait(context.io));
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @backingInt(signal)),
        .stopped, .unknown => 1,
    };
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

test "repository catalog variant resolves and exposes add/remove/list/no-sync/lsign-key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const variant = manifest.findByPath(command_path).?;
    try std.testing.expect(variant.actionCode == 'T');
    try std.testing.expect(variant.typeCode.? == 'r');

    var seen = std.StringHashMap(void).init(arena.allocator());
    defer seen.deinit();
    for ([_][]const u8{ "--add", "--remove", "--list", "--no-sync", "--lsign-key" }) |name| {
        try std.testing.expect(manifest.findOption(variant, name) != null);
        try seen.put(name, {});
    }
    try std.testing.expectEqual(@as(usize, 5), seen.count());

    // Long-form parsing selects the right command path and captures positionals.
    const add = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "utility", "repository", "--add", "cachyos-v3", "https://mirror.c/cachyos" },
    );
    try std.testing.expect(add == .dispatch);
    try std.testing.expectEqualStrings(command_path, add.dispatch.command.path);
    try std.testing.expectEqual(@as(usize, 2), add.dispatch.positionals.len);
    try std.testing.expectEqualStrings("cachyos-v3", add.dispatch.positionals[0]);

    // Shortcode path: -Tr resolves to the repository variant of the utility action.
    const shortcodes = @import("../cli/shortcodes.zig");
    const translation = try shortcodes.translate(arena.allocator(), &manifest, &.{"-Tr"});
    try std.testing.expect(translation == .translated);
    try std.testing.expectEqual(@as(usize, 2), translation.translated.len);
    try std.testing.expectEqualStrings("utility", translation.translated[0]);
    try std.testing.expectEqualStrings("repository", translation.translated[1]);
}

test "repository requires exactly one action flag and add needs a url" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    const missing_action = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "core" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &missing_action, TestRunner{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Choose exactly one") != null);

    tc.stdout.writer.end = 0;
    const conflict = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--add", "--remove", "core" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &conflict, TestRunner{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Choose exactly one") != null);

    tc.stdout.writer.end = 0;
    const missing_url = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--add", "core" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &missing_url, TestRunner{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "requires a repository name and a server URL") != null);

    tc.stdout.writer.end = 0;
    const missing_name = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--remove" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &missing_name, TestRunner{}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Specify the repository name") != null);
}

test "repository list prints configured names in plain and JSON output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    var capture: TestCapture = .{ .names = &.{ "core", "extra", "cachyos-v3" } };

    const plain = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--list" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &plain, &capture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Total 3 repositories: core, extra, cachyos-v3") != null);

    tc.stdout.writer.end = 0;
    const json = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--list", "--json" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &json, &capture));
    try std.testing.expectEqualStrings("[\"core\",\"extra\",\"cachyos-v3\"]\n", tc.stdout.writer.buffered());
}

test "repository list UI mode emits framed output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    var capture: TestCapture = .{ .names = &.{"core"} };
    const ui = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--list", "--ui-mode" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &ui, &capture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "[JSON]") != null);
}

test "repository add calls lsign before mutate and syncs with a fresh manager" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    var capture: TestCapture = .{};
    const add = try parseInvocation(tc.arena.allocator(), &.{
        "utility",     "repository", "--add", "cachyos-v3", "https://mirror.c/cachyos",
        "--lsign-key", "DEADBEEF",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &add, &capture));

    try std.testing.expect(capture.lsign_key != null);
    try std.testing.expectEqualStrings("DEADBEEF", capture.lsign_key.?);
    try std.testing.expect(capture.lsign_before_mutate);
    try std.testing.expect(capture.mutate_action.? == .add);
    try std.testing.expectEqualStrings("cachyos-v3", capture.mutate_name.?);
    try std.testing.expectEqualStrings("https://mirror.c/cachyos", capture.mutate_url.?);
    try std.testing.expect(capture.sync_called);
    try std.testing.expectEqual(@as(usize, 2), capture.manager_inits);
}

test "repository add skips lsign and sync when not requested" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    var capture: TestCapture = .{};
    const add = try parseInvocation(tc.arena.allocator(), &.{
        "utility", "repository", "--add", "cachyos-v3", "https://mirror.c/cachyos", "--no-sync",
    });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &add, &capture));

    try std.testing.expect(capture.lsign_key == null);
    try std.testing.expect(!capture.sync_called);
    try std.testing.expect(capture.mutate_action.? == .add);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Repository cachyos-v3 added") != null);
}

test "repository remove reports unknown repos and syncs on success" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    var capture: TestCapture = .{ .configured = false };
    const remove = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--remove", "missing" });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &remove, &capture));
    try std.testing.expect(capture.mutate_action == null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Could not remove the selected repository") != null);

    tc.stdout.writer.end = 0;
    capture.configured = true;
    const remove_ok = try parseInvocation(tc.arena.allocator(), &.{ "utility", "repository", "--remove", "cachyos-v3" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &remove_ok, &capture));
    try std.testing.expect(capture.mutate_action.? == .remove);
    try std.testing.expectEqualStrings("cachyos-v3", capture.mutate_name.?);
    try std.testing.expect(capture.sync_called);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Repository cachyos-v3 removed") != null);
}

test "repository add surfaces lsign failures before writing config" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    var capture: TestCapture = .{ .lsign_code = 4 };
    const add = try parseInvocation(tc.arena.allocator(), &.{
        "utility", "repository", "--add", "cachyos-v3", "https://mirror.c/cachyos", "--lsign-key", "BAD",
    });
    try std.testing.expectEqual(@as(?u8, 1), try dispatchWithRunner(&tc.context, &add, &capture));
    try std.testing.expect(capture.mutate_action == null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Could not locally sign repository key BAD") != null);
}

const TestRunner = struct {
    fn keyStatus(_: TestRunner, _: *runtime.RuntimeContext, _: []const u8) !KeyStatus {
        return .trusted;
    }
    fn receive(_: TestRunner, _: *runtime.RuntimeContext, _: []const u8, _: bool) !u8 {
        return 0;
    }
    fn lsign(_: TestRunner, _: *runtime.RuntimeContext, _: []const u8, _: bool) !u8 {
        return 0;
    }
    fn list(_: TestRunner, _: *runtime.RuntimeContext, _: *PackageManager.OperationContext) !std.ArrayList([]const u8) {
        return .empty;
    }
    fn mutate(_: TestRunner, _: *runtime.RuntimeContext, _: *PackageManager.OperationContext, _: Action, _: []const u8, _: ?[]const u8) !void {}
    fn sync(_: TestRunner, _: *runtime.RuntimeContext, _: *PackageManager.OperationContext) !void {}
};

const TestCapture = struct {
    names: []const []const u8 = &.{},
    configured: bool = true,
    lsign_code: u8 = 0,
    key_statuses: []const KeyStatus = &.{},
    key_checks: usize = 0,
    received_key: ?[]const u8 = null,

    lsign_key: ?[]const u8 = null,
    lsign_before_mutate: bool = false,
    mutate_action: ?Action = null,
    mutate_name: ?[]const u8 = null,
    mutate_url: ?[]const u8 = null,
    sync_called: bool = false,
    manager_inits: usize = 0,

    fn keyStatus(self: *TestCapture, _: *runtime.RuntimeContext, _: []const u8) !KeyStatus {
        if (self.key_checks >= self.key_statuses.len) return error.UnexpectedKeyringLookup;
        defer self.key_checks += 1;
        return self.key_statuses[self.key_checks];
    }

    fn receive(self: *TestCapture, _: *runtime.RuntimeContext, key: []const u8, _: bool) !u8 {
        self.received_key = key;
        return 0;
    }

    fn lsign(self: *TestCapture, _: *runtime.RuntimeContext, key: []const u8, _: bool) !u8 {
        self.lsign_key = key;
        self.lsign_before_mutate = self.mutate_action == null;
        return self.lsign_code;
    }

    fn list(self: *TestCapture, context: *runtime.RuntimeContext, _: *PackageManager.OperationContext) !std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;
        // Use the runtime allocator (an arena in tests) so deinit(context.allocator)
        // in executeList frees the backing store with the matching allocator.
        try result.appendSlice(context.allocator, self.names);
        return result;
    }

    fn mutate(
        self: *TestCapture,
        _: *runtime.RuntimeContext,
        _: *PackageManager.OperationContext,
        action: Action,
        name: []const u8,
        url: ?[]const u8,
    ) !void {
        self.manager_inits += 1;
        if (action == .remove and !self.configured) return error.RepositoryNotConfigured;
        self.mutate_action = action;
        self.mutate_name = name;
        self.mutate_url = url;
    }

    fn sync(self: *TestCapture, _: *runtime.RuntimeContext, _: *PackageManager.OperationContext) !void {
        self.manager_inits += 1;
        self.sync_called = true;
    }
};

test "repository signing checks trust before changing configuration" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
    const invocation = try parseInvocation(tc.arena.allocator(), &.{
        "utility", "repository", "--add", "--signing-key", fingerprint, "--", "custom", "https://example.invalid",
    });
    const cases = [_]struct { statuses: []const KeyStatus, receive: bool, sign: bool, success: bool }{
        .{ .statuses = &.{.trusted}, .receive = false, .sign = false, .success = true },
        .{ .statuses = &.{ .untrusted, .trusted }, .receive = false, .sign = true, .success = true },
        .{ .statuses = &.{ .missing, .untrusted, .trusted }, .receive = true, .sign = true, .success = true },
        .{ .statuses = &.{ .missing, .missing }, .receive = true, .sign = false, .success = false },
        .{ .statuses = &.{.unusable}, .receive = false, .sign = false, .success = false },
        .{ .statuses = &.{ .untrusted, .untrusted }, .receive = false, .sign = true, .success = false },
    };
    for (cases) |case| {
        var capture: TestCapture = .{ .key_statuses = case.statuses };
        try std.testing.expectEqual(@as(?u8, if (case.success) 0 else 1), try dispatchWithRunner(&tc.context, &invocation, &capture));
        try std.testing.expectEqual(case.receive, capture.received_key != null);
        if (capture.received_key) |key| try std.testing.expectEqualStrings(fingerprint, key);
        try std.testing.expectEqual(case.sign, capture.lsign_key != null);
        if (capture.lsign_key) |key| try std.testing.expectEqualStrings(fingerprint, key);
        try std.testing.expectEqual(case.success, capture.mutate_action != null);
        try std.testing.expectEqual(case.success, capture.sync_called);
    }
}

test "keyring lookup matches the full primary fingerprint and reads trust and usability" {
    const primary = "0123456789ABCDEF0123456789ABCDEF01234567";
    const subkey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const listing =
        "pub:f:255:22:0123456789ABCDEF:1700000000::::::cSC:::::ed25519:::0:\n" ++
        "fpr:::::::::" ++ primary ++ ":\n" ++
        "sub:f:255:22:AAAAAAAAAAAAAAAA:1700000000::::::s:::::ed25519:::\n" ++
        "fpr:::::::::" ++ subkey ++ ":\n";
    try std.testing.expectEqual(KeyStatus.trusted, listedKeyStatus(listing, primary));
    try std.testing.expectEqual(KeyStatus.missing, listedKeyStatus(listing, subkey));
    var modified = listing[0..listing.len].*;
    modified[4] = '-';
    try std.testing.expectEqual(KeyStatus.untrusted, listedKeyStatus(&modified, primary));
    modified[4] = 'r';
    try std.testing.expectEqual(KeyStatus.unusable, listedKeyStatus(&modified, primary));
}
