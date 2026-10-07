const std = @import("std");

/// One active tool reported by `shelly list mise`.
pub const MiseTool = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    RequestedVersion: ?[]const u8 = null,
    InstallPath: ?[]const u8 = null,
    Installed: bool = false,
    Active: bool = false,
    SourceType: ?[]const u8 = null,
    SourcePath: ?[]const u8 = null,
};

/// One tool with a newer allowed version, reported by `shelly list-updates mise`
/// and the "Mise" array of `shelly list-updates all`.
pub const MiseUpdate = struct {
    Name: []const u8 = "",
    CurrentVersion: []const u8 = "",
    NewVersion: []const u8 = "",
    RequestedVersion: ?[]const u8 = null,
    SourcePath: ?[]const u8 = null,
    ReleaseUrl: ?[]const u8 = null,
};

test "MiseTool decodes from wire-format JSON" {
    const json =
        \\{"Name":"node","Version":"26.8.1","RequestedVersion":"26","InstallPath":"/home/u/.local/share/mise/installs/node/26.8.1","Installed":true,"Active":true,"SourceType":"mise.toml","SourcePath":"/home/u/.config/mise/config.toml","Future":1}
    ;
    const parsed = try std.json.parseFromSlice(MiseTool, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("node", parsed.value.Name);
    try std.testing.expectEqualStrings("26", parsed.value.RequestedVersion.?);
    try std.testing.expect(parsed.value.Installed);
    try std.testing.expectEqualStrings("/home/u/.config/mise/config.toml", parsed.value.SourcePath.?);
}

test "MiseTool applies defaults for missing and null fields" {
    const parsed = try std.json.parseFromSlice(MiseTool, std.testing.allocator, "{\"Name\":\"gh\",\"SourcePath\":null}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.Version);
    try std.testing.expect(parsed.value.RequestedVersion == null);
    try std.testing.expect(parsed.value.SourcePath == null);
    try std.testing.expect(!parsed.value.Installed);
}

test "MiseUpdate decodes from wire-format JSON" {
    const json =
        \\{"Name":"npm:@scope/tool","CurrentVersion":"1.0.34","NewVersion":"1.0.46","RequestedVersion":"latest","SourcePath":null,"ReleaseUrl":null}
    ;
    const parsed = try std.json.parseFromSlice(MiseUpdate, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("npm:@scope/tool", parsed.value.Name);
    try std.testing.expectEqualStrings("1.0.46", parsed.value.NewVersion);
    try std.testing.expect(parsed.value.ReleaseUrl == null);
}
