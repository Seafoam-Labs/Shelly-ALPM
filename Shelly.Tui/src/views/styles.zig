//! Shared UI roles inherit the terminal's foreground and background.
const Style = @import("vaxis").Style;

// Keep secondary text readable on both light and dark themes.
pub const secondary: Style = .{};
pub const emphasis: Style = .{ .bold = true };
pub const selected: Style = .{ .bold = true, .reverse = true };
pub const button: Style = .{ .reverse = true };
