const std = @import("std");
const runtime = @import("../services/runtime.zig");

const subdirs = [_][]const u8{
    "icons/hicolor/256x256/apps",
    "icons/hicolor/scalable/apps",
};

pub fn resolveIconPath(buf: []u8, icon_name: []const u8) ?[:0]const u8 {
    if (icon_name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, icon_name, '/') != null) return null;

    const data_home = runtime.data_home;
    if (data_home.len == 0) return null;

    inline for (subdirs) |sub| {
        var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_path_buf, "{s}/{s}", .{ data_home, sub }) catch return null;
        var dir = std.Io.Dir.openDirAbsolute(runtime.io, dir_path, .{ .iterate = true }) catch return null;
        defer dir.close(runtime.io);

        var it = dir.iterate();
        while (it.next(runtime.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (matchStem(entry.name, icon_name)) {
                return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir_path, entry.name }, 0) catch null;
            }
        }
    }
    return null;
}

fn matchStem(entry: []const u8, icon_name: []const u8) bool {
    if (entry.len <= icon_name.len + 1) return false;
    if (!std.mem.startsWith(u8, entry, icon_name)) return false;
    return entry[icon_name.len] == '.';
}

test "matchStem requires icon name followed by an extension" {
    try std.testing.expect(matchStem("blender.png", "blender"));
    try std.testing.expect(matchStem("blender.svg", "blender"));
    try std.testing.expect(!matchStem("blender", "blender"));
    try std.testing.expect(!matchStem("blender2.png", "blender"));
    try std.testing.expect(!matchStem("other.png", "blender"));
    try std.testing.expect(!matchStem("blender.png", "blender-longer"));
}
