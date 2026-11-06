const std = @import("std");

/// Keep both panes usable; narrow terminals retain the single-pane layout.
pub fn listWidth(width: u16, percent: u8) u16 {
    if (width < 64) return width;
    return @intCast(std.math.clamp(@as(u32, width) * percent / 100, 28, width - 28));
}

/// Skip rounding/clamping plateaus without drawing unchanged layouts.
pub fn resize(width: ?u16, percent: u8, wider: bool) ?u8 {
    var candidate = std.math.clamp(percent, 20, 80);
    while (true) {
        const next = std.math.clamp(if (wider) candidate +| 5 else candidate -| 5, 20, 80);
        if (next == candidate) return null;
        candidate = next;
        if (width == null or listWidth(width.?, candidate) != listWidth(width.?, percent)) return candidate;
    }
}

pub fn imagesFit(width: u16, height: u16) bool {
    return width >= 36 and height >= 14;
}

test "split proportions clamp both panes and images require usable space" {
    for ([_]u16{ 64, 80, 160 }) |width| {
        for ([_]u8{ 20, 40, 80 }) |percent| {
            const left = listWidth(width, percent);
            try std.testing.expect(left >= 28 and width - left >= 28);
        }
    }
    try std.testing.expectEqual(@as(u16, 40), listWidth(40, 80));
    try std.testing.expect(!imagesFit(35, 20));
    try std.testing.expect(!imagesFit(60, 13));
    try std.testing.expect(imagesFit(36, 14));
}

test "resize stops at effective limits and can grow away from a clamped minimum" {
    try std.testing.expect(resize(80, 35, false) == null);
    try std.testing.expect(resize(80, 65, true) == null);
    try std.testing.expect(resize(63, 40, true) == null);
    const grown = resize(64, 20, true).?;
    try std.testing.expect(listWidth(64, grown) > listWidth(64, 20));
    for (0..1000) |_| try std.testing.expect(resize(80, 35, false) == null);
}
