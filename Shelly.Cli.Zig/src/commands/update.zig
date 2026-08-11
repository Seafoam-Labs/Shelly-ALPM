const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");

const standard_command_path = "shelly update standard";
const aur_command_path = "shelly update aur";
const flatpak_command_path = "shelly update flatpak";

const UpdateError = error{
    BackendFailed,
    BackendNotImplemented,
    FlatpakNotFound,
};

const Real = struct {
    pub fn run(
        _: Real,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        invocation: *const parser.Invocation,
    ) !void {
        if (std.mem.eql(u8, invocation.command.path, standard_command_path))
            return runStandard(context, operation_context, invocation);
        if (std.mem.eql(u8, invocation.command.path, aur_command_path))
            return runAur(context, operation_context, invocation);
        if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
            return runFlatpak(context, operation_context, invocation);
        return UpdateError.BackendNotImplemented;
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isUpdatePath(invocation.command.path)) return null;
    if (invocation.positionals.len == 0)
        return try reportValidationFailure(context, invocation, "No packages specified.");

    const is_standard = std.mem.eql(u8, invocation.command.path, standard_command_path);
    var confirmed_standard = false;
    if (is_standard and !invocation.globals.no_confirm) {
        confirmed_standard = if (invocation.globals.ui_mode)
            try confirmStandardUpdateUi(context, invocation.positionals)
        else
            try confirmStandardUpdate(context, invocation.positionals);
        if (!confirmed_standard) return 0;
    }

    if (!invocation.globals.ui_mode and needsElevation(invocation) and !elevation.isRoot()) {
        const elevated_arguments = if (is_standard and confirmed_standard)
            try argumentsWithNoConfirm(context.allocator, invocation.arguments)
        else
            invocation.arguments;
        defer if (elevated_arguments.ptr != invocation.arguments.ptr)
            context.allocator.free(elevated_arguments);

        const elevated_exit = elevation.relaunchIfNeeded(context, elevated_arguments) catch |err| {
            try context.stderr.print("Unable to elevate update: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(context, invocation, Real{});
}

fn confirmStandardUpdate(
    context: *runtime.RuntimeContext,
    packages: []const []const u8,
) !bool {
    const names = try std.mem.join(context.allocator, ", ", packages);
    defer context.allocator.free(names);
    try context.stdout.print("Packages to update: {s}\n", .{names});
    try context.stdout.writeAll(
        "WARNING: Updating individual standard packages is a partial upgrade and is unsupported on Arch Linux.\n" ++
            "Partial upgrades can break your system; a full `shelly upgrade standard` is the supported update path.\n",
    );

    const reader = context.stdin orelse {
        try context.stdout.writeAll("Operation cancelled: confirmation input is unavailable.\n");
        try context.stdout.flush();
        return false;
    };
    while (true) {
        try context.stdout.writeAll("Proceed with this partial upgrade? (y/N) ");
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

fn confirmStandardUpdateUi(
    context: *runtime.RuntimeContext,
    packages: []const []const u8,
) !bool {
    const names = try std.mem.join(context.allocator, ", ", packages);
    defer context.allocator.free(names);
    const package_message = try std.fmt.allocPrint(context.allocator, "Packages to update: {s}", .{names});
    defer context.allocator.free(package_message);

    try output.writeInfoFrame(context, package_message);
    try output.writeInfoFrame(
        context,
        "WARNING: Updating individual standard packages is an unsupported partial upgrade and can break your system. " ++
            "Use `shelly upgrade standard` for a full update.",
    );

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
        .backend = .alpm,
        .kind = .update,
        .subject = if (packages.len == 1) packages[0] else null,
    });
    var answer = try operation.ask(.{
        .kind = .confirmation,
        .prompt = "Proceed with this partial upgrade?",
        .default_response = .declined,
    });
    defer answer.deinit(context.allocator);
    const accepted = answer.response == .accepted;
    operation.finish(if (accepted) .success else .cancelled);
    if (!accepted) try output.writeInfoFrame(context, "Operation cancelled.");
    try ui_operation.flush(context);
    return accepted;
}

fn argumentsWithNoConfirm(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, arguments.len + 1);
    @memcpy(result[0..arguments.len], arguments);
    result[arguments.len] = "--no-confirm";
    return result;
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    const opening = try openingMessage(context.allocator, invocation);
    defer context.allocator.free(opening);
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner, opening)
    else
        executeStandard(context, invocation, runner, opening);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
    opening: []const u8,
) anyerror!u8 {
    const succeeded = try standard_single_pane.output(
        context,
        opening,
        invocation.globals.no_confirm,
        runner,
        invocation,
        null,
        null,
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
    opening: []const u8,
) anyerror!u8 {
    return ui_operation.runTransaction(context, invocation, .{
        .opening = opening,
        .success_message = successMessage(invocation),
        .failure_message = failureMessage(invocation),
        .failure_label = "Update failed",
    }, runner);
}

fn runStandard(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, .{ .use_root = true, .operation_context = operation_context });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    const names = try sentinelStrings(context.allocator, invocation.positionals);
    defer freeSentinelStrings(context.allocator, names);
    try manager.update_packages(names, .{});
}

fn runAur(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .root = true,
        .no_check = !optionEnabled(invocation, "--check"),
        .operation_context = operation_context,
    });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);
    try manager.updatePackages(invocation.positionals);
}

fn updateFlatpakTarget(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    manager: anytype,
    target: []const u8,
) !void {
    var application = (manager.find_installed_flatpak(target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return UpdateError.BackendFailed,
    }) orelse return UpdateError.FlatpakNotFound;
    defer application.deinit(context.allocator);

    var detection = (manager.detect_eol_flatpak(&application) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    }) orelse {
        if (!try manager.update_installed_flatpak(target, null))
            return UpdateError.BackendFailed;
        return;
    };
    defer detection.deinit(context.allocator);

    if (detection.rebase) |rebase| {
        if (!try manager.rebase_flatpak(
            rebase.old_ref,
            rebase.new_ref,
            rebase.remote,
            rebase.scope,
            &.{application.id},
        )) return UpdateError.BackendFailed;
        const message = try Zigalpm.flatpak.eol.rebasedMessage(
            context.allocator,
            application.id,
            rebase.new_id,
        );
        defer context.allocator.free(message);
        Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .success, application.id, message);
        return;
    }

    if (detection.reason) |reason| {
        const warning = try Zigalpm.flatpak.eol.eolOnlyWarning(
            context.allocator,
            application.id,
            application.branch,
            reason,
        );
        defer context.allocator.free(warning);
        Zigalpm.flatpak.eol.emitStatus(operation_context, .update, .warning, application.id, warning);
    }
    if (!try manager.update_installed_flatpak(target, null))
        return UpdateError.BackendFailed;
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    try updateFlatpakTarget(context, operation_context, manager, invocation.positionals[0]);
}

fn reportValidationFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
    } else {
        try output.writeFailure(context, message);
    }
    try ui_operation.flush(context);
    return 1;
}

fn openingMessage(allocator: std.mem.Allocator, invocation: *const parser.Invocation) ![]const u8 {
    const names = try std.mem.join(allocator, ", ", invocation.positionals);
    defer allocator.free(names);
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return std.fmt.allocPrint(allocator, "Updating standard packages: {s}...", .{names});
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return std.fmt.allocPrint(allocator, "Rebuilding AUR packages: {s}...", .{names});
    return std.fmt.allocPrint(allocator, "Updating Flatpak: {s}...", .{names});
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return "Standard packages updated successfully!";
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return "AUR packages rebuilt and updated successfully!";
    return "Flatpak updated successfully!";
}

fn failureMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return "Standard package update failed.";
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return "AUR package update failed.";
    return "Flatpak update failed.";
}

fn sentinelStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][:0]const u8 {
    const result = try allocator.alloc([:0]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, result) |value, *destination| {
        destination.* = try allocator.dupeZ(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeSentinelStrings(allocator: std.mem.Allocator, values: [][:0]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn isUpdatePath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

fn needsElevation(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path);
}

test "routes update long forms and canonical shortcodes" {
    const spec = @import("../cli/spec.zig");
    const shortcodes = @import("../cli/shortcodes.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    for ([_]struct {
        arguments: []const []const u8,
        path: []const u8,
    }{
        .{ .arguments = &.{ "update", "standard", "linux" }, .path = standard_command_path },
        .{ .arguments = &.{ "update", "aur", "demo-git" }, .path = aur_command_path },
        .{ .arguments = &.{ "update", "flatpak", "org.example.App" }, .path = flatpak_command_path },
    }) |expected| {
        const outcome = try parser.parse(arena.allocator(), &manifest, expected.arguments);
        try std.testing.expect(outcome == .dispatch);
        try std.testing.expectEqualStrings(expected.path, outcome.dispatch.command.path);
    }

    for ([_]struct {
        shortcode: []const u8,
        package: []const u8,
        path: []const u8,
    }{
        .{ .shortcode = "-Es", .package = "linux", .path = standard_command_path },
        .{ .shortcode = "-Ea", .package = "demo-git", .path = aur_command_path },
        .{ .shortcode = "-Ef", .package = "org.example.App", .path = flatpak_command_path },
    }) |expected| {
        const translation = try shortcodes.translate(
            arena.allocator(),
            &manifest,
            &.{ expected.shortcode, expected.package },
        );
        try std.testing.expect(translation == .translated);
        const outcome = try parser.parse(arena.allocator(), &manifest, translation.arguments().?);
        try std.testing.expect(outcome == .dispatch);
        try std.testing.expectEqualStrings(expected.path, outcome.dispatch.command.path);
    }

    const uppercase_standard = try shortcodes.translate(arena.allocator(), &manifest, &.{ "-ES", "linux" });
    try std.testing.expect(uppercase_standard == .failure);

    const missing_flatpak = try parser.parse(arena.allocator(), &manifest, &.{ "update", "flatpak" });
    try std.testing.expect(missing_flatpak == .failure);
    const extra_flatpak = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "update", "flatpak", "org.example.One", "org.example.Two" },
    );
    try std.testing.expect(extra_flatpak == .failure);
}

test "routes every update backend through shared output lifecycles" {
    const spec = @import("../cli/spec.zig");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Capture = struct {
        calls: usize = 0,
        paths: [3][]const u8 = undefined,

        pub fn run(
            self: *@This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            invocation: *const parser.Invocation,
        ) !void {
            self.paths[self.calls] = invocation.command.path;
            self.calls += 1;
            if (std.mem.eql(u8, invocation.command.path, aur_command_path))
                try std.testing.expect(optionEnabled(invocation, "--check"));
        }
    };
    var capture: Capture = .{};

    for ([_][]const []const u8{
        &.{ "update", "standard", "--no-confirm", "linux", "mesa" },
        &.{ "update", "aur", "--check", "demo-git" },
        &.{ "update", "flatpak", "--ui-mode", "org.example.App" },
    }) |arguments| {
        const outcome = try parser.parse(tc.arena.allocator(), &manifest, arguments);
        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, &capture));
    }
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
    try std.testing.expectEqualStrings(standard_command_path, capture.paths[0]);
    try std.testing.expectEqualStrings(aur_command_path, capture.paths[1]);
    try std.testing.expectEqualStrings(flatpak_command_path, capture.paths[2]);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "linux, mesa") != null);
    try std.testing.expect(std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]") >= 2);
}

test "standard update confirmation is explicit default deny" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var stdin = std.Io.Reader.fixed("maybe\nyes\n");
    tc.context.stdin = &stdin;

    try std.testing.expect(try confirmStandardUpdate(&tc.context, &.{ "linux", "mesa" }));
    const accepted_output = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "Packages to update: linux, mesa") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "partial upgrade") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, accepted_output, "(y/N)"));

    tc.stdout.writer.end = 0;
    var decline_stdin = std.Io.Reader.fixed("\n");
    tc.context.stdin = &decline_stdin;
    try std.testing.expect(!try confirmStandardUpdate(&tc.context, &.{"linux"}));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Operation cancelled.") != null);
}

test "standard UI confirmation uses C sharp compatible yes-no frames" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const response_json = "{\"$kind\":\"a.yesno\",\"QuestionId\":\"1\",\"Accept\":true}";
    const encoded_size = std.base64.standard.Encoder.calcSize(response_json.len);
    const encoded = try tc.arena.allocator().alloc(u8, encoded_size);
    const encoded_response = std.base64.standard.Encoder.encode(encoded, response_json);
    const response_frame = try std.fmt.allocPrint(
        tc.arena.allocator(),
        "[JSON]{s}[/JSON]\n",
        .{encoded_response},
    );
    var stdin = std.Io.Reader.fixed(response_frame);
    tc.context.stdin = &stdin;

    try std.testing.expect(try confirmStandardUpdateUi(&tc.context, &.{"linux"}));
    const rendered = tc.stdout.writer.buffered();
    var frame_iterator = std.mem.splitSequence(u8, rendered, "[JSON]");
    _ = frame_iterator.next();
    var found_confirmation = false;
    while (frame_iterator.next()) |framed| {
        const encoded_end = std.mem.indexOf(u8, framed, "[/JSON]") orelse continue;
        const payload = framed[0..encoded_end];
        const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const decoded = try tc.arena.allocator().alloc(u8, decoded_size);
        try std.base64.standard.Decoder.decode(decoded, payload);
        if (std.mem.indexOf(u8, decoded, "\"$kind\":\"q.yesno\"") == null) continue;
        found_confirmation = true;
        try std.testing.expect(std.mem.indexOf(u8, decoded, "\"QuestionKind\":\"ConflictPkg\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "Proceed with this partial upgrade?") != null);
    }
    try std.testing.expect(found_confirmation);
}

test "update validation rejects empty standard and AUR target lists" {
    const spec = @import("../cli/spec.zig");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());

    for ([_][]const []const u8{
        &.{ "update", "standard", "--ui-mode" },
        &.{ "update", "aur", "--ui-mode" },
    }) |arguments| {
        const outcome = try parser.parse(tc.arena.allocator(), &manifest, arguments);
        try std.testing.expectEqual(@as(?u8, 1), try dispatch(&tc.context, &outcome.dispatch));
    }
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));
}

test "update backend failures return a nonzero status" {
    const spec = @import("../cli/spec.zig");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "update", "flatpak", "org.example.App",
    });
    const Failure = struct {
        pub fn run(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            _: *const parser.Invocation,
        ) !void {
            return error.TestBackendFailure;
        }
    };

    try std.testing.expectEqual(
        @as(u8, 1),
        try executeWithRunner(&tc.context, &outcome.dispatch, Failure{}),
    );
}

test "confirmed elevated standard updates append no-confirm exactly once" {
    const original = [_][]const u8{ "update", "standard", "linux" };
    const elevated = try argumentsWithNoConfirm(std.testing.allocator, &original);
    defer std.testing.allocator.free(elevated);
    try std.testing.expectEqual(@as(usize, 4), elevated.len);
    try std.testing.expectEqualStrings("--no-confirm", elevated[3]);
}

const EolUpdateTestManager = struct {
    allocator: std.mem.Allocator,
    application: ?Zigalpm.flatpak.types.InstalledApplication = null,
    detection: ?Zigalpm.flatpak.EolDetection = null,
    find_error: bool = false,
    update_result: bool = true,
    rebase_result: bool = true,
    update_called: bool = false,
    rebase_called: bool = false,
    rebase_old_ref: ?[]const u8 = null,
    rebase_new_ref: ?[]const u8 = null,
    rebase_remote: ?[]const u8 = null,
    rebase_previous_ids: []const []const u8 = &.{},

    pub fn find_installed_flatpak(
        self: @This(),
        _: []const u8,
    ) !?Zigalpm.flatpak.types.InstalledApplication {
        if (self.find_error) return error.TestFindFailure;
        if (self.application == null) return null;
        const source = self.application.?;
        return try Zigalpm.flatpak.types.InstalledApplication.fromWire(self.allocator, .{
            .id = source.id,
            .name = source.name,
            .arch = source.arch,
            .branch = source.branch,
            .summary = source.summary,
            .version = source.version,
            .latest_commit = source.latest_commit,
            .origin = source.origin,
            .kind = @enumFromInt(@intFromEnum(source.kind)),
            .installed_size = source.installed_size,
            .scope = Zigalpm.flatpak.types.Scope.toWire(source.scope),
            .eol = source.eol,
            .eol_rebase = source.eol_rebase,
        });
    }

    pub fn detect_eol_flatpak(
        self: @This(),
        _: *const Zigalpm.flatpak.types.InstalledApplication,
    ) !?Zigalpm.flatpak.EolDetection {
        const source = self.detection orelse return null;
        var reason: ?[]u8 = null;
        if (source.reason) |value| reason = try self.allocator.dupe(u8, value);
        var rebase: ?Zigalpm.flatpak.EolRebase = null;
        if (source.rebase) |value| {
            rebase = try cloneEolRebase(self.allocator, value);
        }
        return .{ .reason = reason, .rebase = rebase };
    }

    pub fn update_installed_flatpak(
        self: *@This(),
        _: []const u8,
        _: ?[]const u8,
    ) !bool {
        self.update_called = true;
        return self.update_result;
    }

    pub fn rebase_flatpak(
        self: *@This(),
        old_ref: []const u8,
        new_ref: []const u8,
        remote: []const u8,
        _: Zigalpm.flatpak.Scope,
        previous_ids: []const []const u8,
    ) !bool {
        self.rebase_called = true;
        self.rebase_old_ref = try self.allocator.dupe(u8, old_ref);
        self.rebase_new_ref = try self.allocator.dupe(u8, new_ref);
        self.rebase_remote = try self.allocator.dupe(u8, remote);
        const duped_ids = try self.allocator.alloc([]const u8, previous_ids.len);
        for (previous_ids, duped_ids) |source, *dest| {
            dest.* = try self.allocator.dupe(u8, source);
        }
        self.rebase_previous_ids = duped_ids;
        return self.rebase_result;
    }
};

fn cloneEolRebase(
    allocator: std.mem.Allocator,
    source: Zigalpm.flatpak.EolRebase,
) !Zigalpm.flatpak.EolRebase {
    return .{
        .old_ref = try allocator.dupe(u8, source.old_ref),
        .new_ref = try allocator.dupe(u8, source.new_ref),
        .new_id = try allocator.dupe(u8, source.new_id),
        .new_branch = try allocator.dupe(u8, source.new_branch),
        .remote = try allocator.dupe(u8, source.remote),
        .scope = source.scope,
    };
}

fn makeInstalledApplication(id: []const u8, branch: []const u8) Zigalpm.flatpak.types.InstalledApplication {
    return .{
        .id = @constCast(id),
        .name = @constCast(id),
        .arch = @constCast("x86_64"),
        .branch = @constCast(branch),
        .summary = @constCast(""),
        .version = @constCast("1.0"),
        .latest_commit = @constCast("abc"),
        .origin = @constCast("flathub"),
        .kind = .app,
        .installed_size = 0,
        .scope = .system,
        .eol = null,
        .eol_rebase = null,
    };
}

fn makeEolRebaseDetection(new_id: []const u8, new_branch: []const u8) Zigalpm.flatpak.EolDetection {
    return .{
        .reason = null,
        .rebase = .{
            .old_ref = @constCast("app/dev.bragefuglseth.Keypunch/x86_64/stable"),
            .new_ref = @constCast("app/no.bragefuglseth.Keypunch/x86_64/stable"),
            .new_id = @constCast(new_id),
            .new_branch = @constCast(new_branch),
            .remote = @constCast("flathub"),
            .scope = .system,
        },
    };
}

test "Flatpak update EOL rebase dispatches to the replacement" {
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

    var manager: EolUpdateTestManager = .{
        .allocator = arena.allocator(),
        .application = makeInstalledApplication("dev.bragefuglseth.Keypunch", "stable"),
        .detection = makeEolRebaseDetection("no.bragefuglseth.Keypunch", "stable"),
    };

    try updateFlatpakTarget(&context, &operations, &manager, "dev.bragefuglseth.Keypunch");
    try std.testing.expect(manager.rebase_called);
    try std.testing.expect(!manager.update_called);
    try std.testing.expectEqualStrings("app/dev.bragefuglseth.Keypunch/x86_64/stable", manager.rebase_old_ref.?);
    try std.testing.expectEqualStrings("app/no.bragefuglseth.Keypunch/x86_64/stable", manager.rebase_new_ref.?);
    try std.testing.expectEqualStrings("flathub", manager.rebase_remote.?);
    try std.testing.expectEqual(@as(usize, 1), manager.rebase_previous_ids.len);
    try std.testing.expectEqualStrings("dev.bragefuglseth.Keypunch", manager.rebase_previous_ids[0]);
}

test "Flatpak update EOL-only warns and proceeds with the normal update" {
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

    var manager: EolUpdateTestManager = .{
        .allocator = arena.allocator(),
        .application = makeInstalledApplication("org.example.Dead", "stable"),
        .detection = .{ .reason = @constCast("No longer maintained"), .rebase = null },
    };

    try updateFlatpakTarget(&context, &operations, &manager, "org.example.Dead");
    try std.testing.expect(!manager.rebase_called);
    try std.testing.expect(manager.update_called);
}

test "Flatpak update without EOL runs the normal update path" {
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

    var manager: EolUpdateTestManager = .{
        .allocator = arena.allocator(),
        .application = makeInstalledApplication("org.example.App", "stable"),
        .detection = null,
    };

    try updateFlatpakTarget(&context, &operations, &manager, "org.example.App");
    try std.testing.expect(!manager.rebase_called);
    try std.testing.expect(manager.update_called);
}

test "Flatpak update returns FlatpakNotFound when the ref is not installed" {
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

    var manager: EolUpdateTestManager = .{
        .allocator = arena.allocator(),
        .application = null,
    };

    try std.testing.expectError(
        UpdateError.FlatpakNotFound,
        updateFlatpakTarget(&context, &operations, &manager, "org.example.Missing"),
    );
}
