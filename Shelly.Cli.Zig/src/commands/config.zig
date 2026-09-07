const std = @import("std");
const Zigalpm = @import("Zigalpm");
const environment = Zigalpm.appimage.environment;
const xdg = @import("../runtime/xdg.zig");
const config_manager = @import("../config/manager.zig");
const output = @import("../output/config.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.startsWith(u8, invocation.command.path, "shelly config ")) return null;
    if (std.mem.eql(u8, invocation.command.path, "shelly config appimage")) {
        configureAppImage(context, invocation) catch |err| {
            const message = try std.fmt.allocPrint(context.allocator, "Could not save AppImage environment: {t}", .{err});
            defer context.allocator.free(message);
            if (invocation.globals.ui_mode) try output.writeErrorFrame(context, message) else try output.writeFailure(context, message);
            return 1;
        };
        if (invocation.globals.ui_mode) try output.writeInfoFrame(context, "AppImage environment saved.") else try output.writeSuccess(context, "AppImage environment saved.");
        return 0;
    }
    const manager = config_manager.Manager.init(context);

    if (std.mem.eql(u8, invocation.command.path, "shelly config list")) {
        const config = try manager.read();
        if (invocation.globals.ui_mode) {
            try output.writeConfigFrame(context, &config);
        } else if (invocation.globals.json) {
            try output.writeDictionaryJson(context.allocator, &config, context.stdout);
            try context.stdout.writeByte('\n');
        } else {
            try output.writeListPlain(context, &config);
        }
        return 0;
    }

    if (std.mem.eql(u8, invocation.command.path, "shelly config get")) {
        const key = invocation.positionals[0];
        const value = try manager.get(key);
        if (invocation.globals.ui_mode) {
            if (value) |actual| {
                try output.writeSingleValueFrame(context, key, actual);
            } else {
                try output.writeErrorFrame(
                    context,
                    try std.fmt.allocPrint(context.allocator, "Unknown configuration key: {s}", .{key}),
                );
            }
        } else if (value) |actual| {
            try context.stdout.print("{s}\n", .{actual});
        } else {
            try output.writeFailure(
                context,
                try std.fmt.allocPrint(context.allocator, "Unknown configuration key: {s}", .{key}),
            );
        }
        return 0;
    }

    if (std.mem.eql(u8, invocation.command.path, "shelly config set")) {
        const key = invocation.positionals[0];
        const value = invocation.positionals[1];
        const updated = try manager.update(key, value);
        const message = if (updated)
            try std.fmt.allocPrint(context.allocator, "Set {s} to {s}", .{ key, value })
        else
            try std.fmt.allocPrint(context.allocator, "Failed to set configuration key: {s}", .{key});
        if (invocation.globals.ui_mode) {
            if (updated) try output.writeInfoFrame(context, message) else try output.writeErrorFrame(context, message);
        } else if (updated) {
            try output.writeSuccess(context, message);
        } else {
            try output.writeFailure(context, message);
        }
        return 0;
    }

    if (std.mem.eql(u8, invocation.command.path, "shelly config reset")) {
        try manager.reset();
        const message = "Configuration reset to defaults.";
        if (invocation.globals.ui_mode)
            try output.writeInfoFrame(context, message)
        else
            try output.writeSuccess(context, message);
        return 0;
    }

    if (std.mem.eql(u8, invocation.command.path, "shelly config parallel")) {
        const value = invocation.positionals[0];
        const updated = try manager.update("ParallelDownloadCount", value);
        const message = if (updated)
            try std.fmt.allocPrint(context.allocator, "Set parallel downloads to {s}", .{value})
        else
            "Failed to set parallel downloads.";
        if (invocation.globals.ui_mode) {
            if (updated) try output.writeInfoFrame(context, message) else try output.writeErrorFrame(context, message);
        } else if (updated) {
            try output.writeSuccess(context, message);
        } else {
            try output.writeFailure(context, message);
        }
        return 0;
    }

    return null;
}

fn environmentOption(invocation: *const parser.Invocation) !parser.ParsedOption {
    var selected: ?parser.ParsedOption = null;
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, "--set-env") and !std.mem.eql(u8, option.name, "--unset-env") and
            !std.mem.eql(u8, option.name, "--clear-env") and !std.mem.eql(u8, option.name, "--replace-env")) continue;
        if (selected != null) return error.ExactlyOneEnvironmentOperationRequired;
        if (std.mem.eql(u8, option.name, "--clear-env") and !std.mem.eql(u8, option.value orelse "true", "true"))
            return error.ExactlyOneEnvironmentOperationRequired;
        selected = option;
    }
    return selected orelse error.ExactlyOneEnvironmentOperationRequired;
}

test "AppImage environment command rejects conflicting and duplicate operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try @import("../cli/spec.zig").Manifest.load(allocator);
    const valid = try parser.parse(allocator, &manifest, &.{ "config", "appimage", "Editor", "--set-env", "A= a=b " });
    try std.testing.expectEqualStrings("A= a=b ", (try environmentOption(&valid.dispatch)).value.?);
    for ([_][]const []const u8{
        &.{ "config", "appimage", "Editor" },
        &.{ "config", "appimage", "Editor", "--set-env", "A=1", "--set-env", "A=2" },
        &.{ "config", "appimage", "Editor", "--clear-env", "--unset-env", "A" },
    }) |argv| {
        const parsed = try parser.parse(allocator, &manifest, argv);
        try std.testing.expectError(error.ExactlyOneEnvironmentOperationRequired, environmentOption(&parsed.dispatch));
    }
}

fn configureAppImage(context: *runtime.RuntimeContext, invocation: *const parser.Invocation) !void {
    const option = try environmentOption(invocation);
    var replacement: ?[]environment.Variable = null;
    defer if (replacement) |variables| environment.free(context.allocator, variables);
    const mutation: environment.Mutation = if (std.mem.eql(u8, option.name, "--set-env")) blk: {
        const assignment = option.value orelse return error.EnvironmentAssignmentRequired;
        const separator = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.EnvironmentAssignmentRequired;
        break :blk .{ .set = .{ .key = assignment[0..separator], .value = assignment[separator + 1 ..] } };
    } else if (std.mem.eql(u8, option.name, "--unset-env"))
        .{ .unset = option.value orelse return error.InvalidEnvironmentName }
    else if (std.mem.eql(u8, option.name, "--clear-env"))
        .clear
    else blk: {
        replacement = try environment.parseJson(context.allocator, option.value orelse return error.EnvironmentObjectRequired);
        break :blk .{ .replace = replacement.? };
    };
    const configuration = try config_manager.Manager.init(context).read();
    const install_path = configuration.values.get("AppImageInstallPath");
    const fallback = try xdg.binHome(context);
    defer context.allocator.free(fallback);
    const config_home = try xdg.configHome(context);
    defer context.allocator.free(config_home);
    const database = try std.fs.path.join(context.allocator, &.{ config_home, "shelly", "appimage-metadata-v2.db" });
    defer context.allocator.free(database);
    var manager = Zigalpm.AppImageManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = if (install_path != null and install_path.? == .string and install_path.?.string.len > 0) install_path.?.string else fallback,
        .local_db_path = database,
    };
    defer manager.deinit();
    try manager.configureEnvironment(invocation.positionals[0], mutation);
}
