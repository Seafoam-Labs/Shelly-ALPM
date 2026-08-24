const std = @import("std");

pub const wide_layout_min_width: c_int = 1600;

pub fn usesWideLayout(available_width: c_int) bool {
    return available_width >= wide_layout_min_width;
}

test "settings layout widens only when the window has enough room" {
    try std.testing.expect(!usesWideLayout(700));
    try std.testing.expect(!usesWideLayout(1280));
    try std.testing.expect(!usesWideLayout(1599));
    try std.testing.expect(usesWideLayout(1600));
    try std.testing.expect(usesWideLayout(1920));
    try std.testing.expect(usesWideLayout(3840));
}
