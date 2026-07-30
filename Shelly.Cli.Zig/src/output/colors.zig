const std = @import("std");
const runtime = @import("../runtime/context.zig");
const output_config = @import("config.zig");

/// Semantic colors used for terminal output. Each entry maps to an ANSI
/// escape code from the standard 16-color palette by default, so terminal
/// themes can restyle them. Entries can also be remapped at runtime via
/// `set` (e.g. from user configuration).
pub const Color = enum {
    white,
    green,
    yellow,
    red,
    blue,
    cyan,
    magenta,
    gray,

    // Semantic roles.
    success,
    err,
    warning,
    info,
    heading,
    highlight,
    dim,

    const count = @typeInfo(Color).@"enum".fields.len;
};

pub const reset = "\x1b[0m";

/// Default palette: standard 16-color SGR codes, remapped by terminal themes.
const default_palette = [Color.count][]const u8{
    "\x1b[37m", // white
    "\x1b[32m", // green
    "\x1b[33m", // yellow
    "\x1b[31m", // red
    "\x1b[34m", // blue
    "\x1b[36m", // cyan
    "\x1b[35m", // magenta
    "\x1b[90m", // gray
    "\x1b[32m", // success
    "\x1b[31m", // err
    "\x1b[33m", // warning
    "\x1b[36m", // info
    "\x1b[34m", // heading
    "\x1b[32m", // highlight
    "\x1b[90m", // dim
};

var palette = default_palette;

/// Return the active ANSI escape code for a color.
pub fn colorCode(color: Color) []const u8 {
    return palette[@intFromEnum(color)];
}

/// Remap a color to a custom ANSI escape sequence (must have static lifetime,
/// e.g. a string literal or a buffer owned by the caller).
pub fn set(color: Color, code: []const u8) void {
    palette[@intFromEnum(color)] = code;
}

/// Restore all colors to the default palette.
pub fn resetPalette() void {
    palette = default_palette;
}

/// Write `code` only when the terminal supports ANSI escapes.
pub fn writeCode(context: *const runtime.RuntimeContext, color: Color) !void {
    if (output_config.supportsAnsi(context)) try context.stdout.writeAll(colorCode(color));
}

/// Write the reset code only when the terminal supports ANSI escapes.
pub fn writeReset(context: *const runtime.RuntimeContext) !void {
    if (output_config.supportsAnsi(context)) try context.stdout.writeAll(reset);
}

/// Print a colored line to stdout, falling back to plain text when ANSI is not supported.
pub fn printLine(
    context: *const runtime.RuntimeContext,
    color: Color,
    comptime format: []const u8,
    args: anytype,
) !void {
    if (output_config.supportsAnsi(context)) {
        try context.stdout.writeAll(colorCode(color));
        try context.stdout.print(format, args);
        try context.stdout.writeAll(reset);
        try context.stdout.writeByte('\n');
    } else {
        try context.stdout.print(format, args);
        try context.stdout.writeByte('\n');
    }
}

test "palette defaults and remapping" {
    try std.testing.expectEqualStrings("\x1b[32m", colorCode(.green));
    set(.green, "\x1b[38;2;0;255;0m");
    try std.testing.expectEqualStrings("\x1b[38;2;0;255;0m", colorCode(.green));
    resetPalette();
    try std.testing.expectEqualStrings("\x1b[32m", colorCode(.green));
}
