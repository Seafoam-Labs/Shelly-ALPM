const std = @import("std");

const BackupFile = @This();
name: []const u8,
/// Archive PKGINFO backup records have no installed-content hash yet.
hash: ?[]const u8 = null,

pub fn parseLocal(value: []const u8) !BackupFile {
    const tab = std.mem.indexOfScalar(u8, value, '\t') orelse return error.InvalidBackup;
    return .{ .name = value[0..tab], .hash = value[tab + 1 ..] };
}
