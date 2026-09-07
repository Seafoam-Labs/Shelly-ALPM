const std = @import("std");
const help = @import("help.zig");
const parser = @import("parser.zig");
const shortcodes = @import("shortcodes.zig");
const spec = @import("spec.zig");
const runtime = @import("../runtime/context.zig");
const Zigalpm = @import("Zigalpm");

pub const sandbox_wrapper_argument = Zigalpm.builder.sandbox.wrapper_argument;

pub fn run(context: *runtime.RuntimeContext, arguments: []const []const u8) !u8 {
    const manifest = try spec.Manifest.load(context.allocator);
    const translation = try shortcodes.translate(context.allocator, &manifest, arguments);
    return switch (translation) {
        .unchanged => |value| runTranslated(context, &manifest, value),
        .translated => |value| runTranslated(context, &manifest, value),
        .expanded => |values| runExpanded(context, &manifest, values),
        .failure => |message| {
            try context.stderr.print("{s}\n", .{message});
            return 1;
        },
    };
}

fn runTranslated(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    arguments: []const []const u8,
) !u8 {
    const outcome = try parser.parse(context.allocator, manifest, arguments);
    return switch (outcome) {
        .help => |command| renderHelp(context, manifest, command),
        .version => |globals| printVersion(context, manifest, globals.json),
        .dispatch => |invocation| context.dispatch(&invocation),
        .failure => |failure| renderFailure(context, manifest, failure),
    };
}

fn runExpanded(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    arguments: []const []const []const u8,
) !u8 {
    var exit_code: u8 = 0;
    for (arguments) |current| {
        const current_exit_code = try runTranslated(context, manifest, current);
        if (current_exit_code != 0 and exit_code == 0) exit_code = current_exit_code;
    }
    return exit_code;
}

fn renderHelp(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
) !u8 {
    try help.render(context.allocator, manifest, command, context.stdout);
    return 0;
}

const AutomationCapability = struct {
    name: []const u8,
    version: u32,
};

const automation_capabilities = [_]AutomationCapability{
    .{ .name = "remora.build-backend", .version = 1 },
    .{ .name = "build.review", .version = 1 },
    .{ .name = "build.result", .version = 1 },
    .{ .name = "build.isolated", .version = 1 },
    .{ .name = "build.package-destination", .version = 1 },
    .{ .name = "operation.cancellation", .version = 1 },
    .{ .name = "resolve.package-base", .version = 1 },
};

fn printVersion(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    json_output: bool,
) !u8 {
    if (!json_output) {
        try context.stdout.print("{s}\n", .{manifest.informationalVersion});
        return 0;
    }

    var json: std.json.Stringify = .{ .writer = context.stdout };
    try json.beginObject();
    try json.objectField("schemaVersion");
    try json.write(1);
    try json.objectField("name");
    try json.write(manifest.binary);
    try json.objectField("version");
    try json.write(manifest.version);
    try json.objectField("capabilities");
    try json.beginArray();
    for (automation_capabilities) |capability| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(capability.name);
        try json.objectField("version");
        try json.write(capability.version);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try context.stdout.writeByte('\n');
    return 0;
}

fn renderFailure(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    failure: parser.Failure,
) !u8 {
    try context.stderr.print("{s}\n\n", .{failure.message});
    if (failure.leading_help_newline) try context.stdout.writeByte('\n');
    try help.render(context.allocator, manifest, failure.help_command, context.stdout);
    return 1;
}

/// Entry point for the re-executed Landlock sandbox wrapper. Applies the
/// policy parsed from `arguments` and replaces the process with the child
/// command. Invoked from `main` before manifest loading or argument parsing
/// so the wrapped bash body never touches the CLI grammar. Returns the exit
/// code to terminate with; on success it does not return.
pub fn runSandboxExec(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    arguments: []const []const u8,
) u8 {
    const sandbox = Zigalpm.builder.sandbox;
    const parsed = sandbox.parseWrapperArguments(allocator, arguments) catch |err| {
        stderr.print("shelly sandbox: invalid wrapper arguments: {t}\n", .{err}) catch {};
        return 1;
    };
    defer {
        allocator.free(parsed.read_write_paths);
        allocator.free(parsed.read_only_paths);
    }

    Zigalpm.builder.setNoNewPrivs() catch {
        stderr.print("shelly sandbox: unable to lock process privileges\n", .{}) catch {};
        return 1;
    };

    const read_write_paths = joinSandboxPaths(allocator, sandbox.base_read_write_paths, parsed.read_write_paths) catch {
        stderr.print("shelly sandbox: out of memory\n", .{}) catch {};
        return 1;
    };
    defer allocator.free(read_write_paths);
    const read_only_paths = joinSandboxPaths(allocator, sandbox.base_read_only_paths, parsed.read_only_paths) catch {
        stderr.print("shelly sandbox: out of memory\n", .{}) catch {};
        return 1;
    };
    defer allocator.free(read_only_paths);

    sandbox.applyPolicy(allocator, .{
        .read_write_paths = read_write_paths,
        .read_only_paths = read_only_paths,
    }) catch |err| {
        stderr.print("shelly sandbox: unable to confine step: {t}\n", .{err}) catch {};
        return 1;
    };

    return execSandboxChild(allocator, environ, stderr, parsed.child_argv);
}

fn joinSandboxPaths(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    extra: []const []const u8,
) ![][]const u8 {
    const joined = try allocator.alloc([]const u8, base.len + extra.len);
    @memcpy(joined[0..base.len], base);
    @memcpy(joined[base.len..], extra);
    return joined;
}

fn execSandboxChild(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    child_argv: []const []const u8,
) u8 {
    switch (@import("builtin").os.tag) {
        .linux => {
            const argv = buildPosixArgv(allocator, child_argv) catch {
                stderr.print("shelly sandbox: out of memory\n", .{}) catch {};
                return 1;
            };
            const rc = std.os.linux.execve(argv[0].?, argv.ptr, environ.block.slice.ptr);
            stderr.print(
                "shelly sandbox: unable to execute {s}: {t}\n",
                .{ child_argv[0], std.os.linux.errno(@intCast(rc)) },
            ) catch {};
            return 127;
        },
        else => {
            stderr.print("shelly sandbox: unsupported platform\n", .{}) catch {};
            return 1;
        },
    }
}

fn buildPosixArgv(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) ![:null]?[*:0]const u8 {
    const argv = try allocator.alloc(?[*:0]const u8, args.len + 1);
    errdefer {
        for (argv) |entry| if (entry) |value| allocator.free(std.mem.span(value));
        allocator.free(argv);
    }
    for (args, 0..) |arg, index| {
        argv[index] = (try allocator.dupeZ(u8, arg)).ptr;
    }
    argv[args.len] = null;
    return argv[0..args.len :null];
}

test "no arguments dispatch upgrade all through the injected runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var observed = false;
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .dispatcher = .{ .user_data = &observed, .call = struct {
            fn dispatch(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                invocation: *const parser.Invocation,
            ) !u8 {
                const called: *bool = @ptrCast(@alignCast(data.?));
                called.* = true;
                try std.testing.expectEqualStrings("shelly upgrade all", invocation.command.path);
                return 37;
            }
        }.dispatch },
    };

    try std.testing.expectEqual(@as(u8, 37), try run(&context, &.{}));
    try std.testing.expect(observed);
}

test "version remains human-readable unless JSON capabilities are requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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

    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{"--version"}));
    const manifest = try spec.Manifest.load(arena.allocator());
    const expected_plain = try std.fmt.allocPrint(arena.allocator(), "{s}\n", .{manifest.informationalVersion});
    try std.testing.expectEqualStrings(expected_plain, stdout.writer.buffered());
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);

    stdout.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{ "--version", "--json" }));
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stdout.writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), object.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings("shelly", object.get("name").?.string);
    try std.testing.expectEqualStrings(manifest.version, object.get("version").?.string);
    const capabilities = object.get("capabilities").?.array.items;
    try std.testing.expectEqual(automation_capabilities.len, capabilities.len);
    try std.testing.expectEqualStrings(
        "remora.build-backend",
        capabilities[0].object.get("name").?.string,
    );
    try std.testing.expectEqual(@as(i64, 1), capabilities[0].object.get("version").?.integer);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "help and parser errors bypass dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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

    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{ "search", "standard", "--help" }));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "shelly search standard [<package>]") != null);

    stdout.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{"-Sah"}));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "shelly search aur <query>...") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "AurManager.searchPackages") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Implementation:") == null);

    stdout.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{"-Iah"}));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "shelly install aur [<packages>...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "AurManager.installPackages") == null);

    stdout.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 1), try run(&context, &.{ "config", "get" }));
    try std.testing.expect(std.mem.indexOf(u8, stderr.writer.buffered(), "Required argument 'key' missing") != null);
}

test "combined search shortcodes dispatch each selected type and route modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    const Capture = struct { calls: usize = 0 };
    var capture: Capture = .{};
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .dispatcher = .{ .user_data = &capture, .call = struct {
            fn dispatch(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                invocation: *const parser.Invocation,
            ) !u8 {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                const expected_paths = [_][]const u8{
                    "shelly search standard",
                    "shelly search aur",
                    "shelly search flatpak",
                };
                try std.testing.expect(observed.calls < expected_paths.len);
                try std.testing.expectEqualStrings(expected_paths[observed.calls], invocation.command.path);
                try std.testing.expectEqual(@as(usize, if (observed.calls == 0) 1 else 0), invocation.options.len);
                if (observed.calls == 0)
                    try std.testing.expectEqualStrings("--available", invocation.options[0].name);
                observed.calls += 1;
                return 0;
            }
        }.dispatch },
    };

    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{ "-Ssafv", "firefox" }));
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
}

test "old type-first and implicit-standard inputs are rejected without rewriting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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

    try std.testing.expectEqual(@as(u8, 1), try run(&context, &.{ "aur", "install", "pkg" }));
    stdout.writer.end = 0;
    stderr.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 1), try run(&context, &.{ "install", "pkg" }));
}
