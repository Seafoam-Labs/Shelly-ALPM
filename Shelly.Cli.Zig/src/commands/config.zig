const std = @import("std");
const config_manager = @import("../config/manager.zig");
const output = @import("../output/config.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.startsWith(u8, invocation.command.path, "shelly config ")) return null;
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
