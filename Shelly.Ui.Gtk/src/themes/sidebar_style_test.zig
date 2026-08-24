const std = @import("std");
test "expanded Midnight sidebar keeps its original width" {
    const css = @embedFile("theme-midnight.css");
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        ".theme-midnight .app-sidebar.sidebar-expanded {\n  min-width: 13em;\n}",
    ) != null);
}
