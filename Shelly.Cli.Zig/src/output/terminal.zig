const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("../runtime/context.zig");

pub const default_columns: usize = 80;

/// Returns the current terminal column count when it can be discovered. Live
/// TTY dimensions take precedence over COLUMNS so window and font-size changes
/// are reflected without restarting the command.
pub fn detectedColumns(context: *const runtime.RuntimeContext) ?usize {
    return liveColumns(context) orelse configuredColumns(context);
}

/// Returns a rendering width with the rightmost terminal cell reserved. This
/// avoids automatic wrapping when a terminal places the cursor at its margin.
pub fn usableWidth(
    context: *const runtime.RuntimeContext,
    fallback_columns: usize,
    minimum_width: usize,
) usize {
    const columns = detectedColumns(context) orelse fallback_columns;
    return @max(minimum_width, columns -| 1);
}

/// Interactive tables should be constrained only when stdout is a terminal.
/// Redirected output retains its natural width for compatibility and piping.
pub fn interactiveWidth(context: *const runtime.RuntimeContext) ?usize {
    if (!context.stdout_is_tty) return null;
    return usableWidth(context, default_columns, 1);
}

fn liveColumns(context: *const runtime.RuntimeContext) ?usize {
    if (!context.stdout_is_tty) return null;
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;

    var size: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const result = context.io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return null;
    if (result.device_io_control < 0 or size.col == 0) return null;
    return size.col;
}

fn configuredColumns(context: *const runtime.RuntimeContext) ?usize {
    const environment = context.environment orelse return null;
    const columns = environment.get("COLUMNS") orelse return null;
    const parsed = std.fmt.parseInt(usize, columns, 10) catch return null;
    return if (parsed > 0) parsed else null;
}

test "terminal width validates COLUMNS and reserves the right edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };

    try environment.put("COLUMNS", "120");
    try std.testing.expectEqual(@as(usize, 119), usableWidth(&context, default_columns, 5));
    try environment.put("COLUMNS", "invalid");
    try std.testing.expectEqual(@as(usize, 79), usableWidth(&context, default_columns, 5));
    try environment.put("COLUMNS", "1");
    try std.testing.expectEqual(@as(usize, 5), usableWidth(&context, default_columns, 5));
    try std.testing.expectEqual(@as(?usize, null), interactiveWidth(&context));
}
