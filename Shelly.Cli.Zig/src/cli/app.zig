const std = @import("std");
const help = @import("help.zig");
const parser = @import("parser.zig");
const shortcodes = @import("shortcodes.zig");
const spec = @import("spec.zig");
const runtime = @import("../runtime/context.zig");

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
        .version => printVersion(context, manifest),
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

fn printVersion(context: *runtime.RuntimeContext, manifest: *const spec.Manifest) !u8 {
    try context.stdout.print("{s}\n", .{manifest.informationalVersion});
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
