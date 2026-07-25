const std = @import("std");

pub const UpdateType = enum(u8) {
    None = 0,
    StaticUrl = 1,
    GitHub = 2,
    GitLab = 3,
    Codeberg = 4,
    Forgejo = 5,

    pub fn toCliString(self: UpdateType) []const u8 {
        return switch (self) {
            .None => "None",
            .StaticUrl => "StaticUrl",
            .GitHub => "GitHub",
            .GitLab => "GitLab",
            .Codeberg => "Codeberg",
            .Forgejo => "Forgejo",
        };
    }
};

pub const AppImage = struct {
    Name: []const u8 = "",
    DesktopName: []const u8 = "",
    Version: []const u8 = "",
    IconName: []const u8 = "",
    Description: []const u8 = "",
    SizeOnDisk: i64 = 0,
    UpdateURl: []const u8 = "",
    RawUpdateInfo: []const u8 = "",
    RepoOwner: ?[]const u8 = null,
    RepoName: ?[]const u8 = null,
    UpdateType: UpdateType = .None,
    AllowPrerelease: bool = false,
    CommandLineArgs: ?[]const u8 = null,
    Path: ?[]const u8 = null,
};

pub const AppImageUpdate = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    DownloadUrl: []const u8 = "",
    IsUpdateAvailable: bool = false,
};

test "AppImage decodes from wire-format JSON" {
    const json =
        \\{"Name":"Blender","DesktopName":"Blender","Version":"4.2.0","IconName":"blender","Description":"3D modeling","SizeOnDisk":250000000,"UpdateURl":"seafoam-labs/blender","RawUpdateInfo":"","RepoOwner":"seafoam-labs","RepoName":"blender","UpdateType":2,"AllowPrerelease":false,"CommandLineArgs":null,"Path":"/home/user/.local/bin/blender.AppImage"}
    ;
    const parsed = try std.json.parseFromSlice(AppImage, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const app = parsed.value;
    try std.testing.expectEqualStrings("Blender", app.Name);
    try std.testing.expectEqualStrings("blender", app.IconName);
    try std.testing.expectEqual(@as(i64, 250000000), app.SizeOnDisk);
    try std.testing.expectEqual(UpdateType.GitHub, app.UpdateType);
    try std.testing.expectEqualStrings("seafoam-labs/blender", app.UpdateURl);
    try std.testing.expectEqualStrings("seafoam-labs", app.RepoOwner.?);
    try std.testing.expectEqualStrings("/home/user/.local/bin/blender.AppImage", app.Path.?);
    try std.testing.expect(app.CommandLineArgs == null);
}

test "AppImage applies defaults for missing optional fields" {
    const parsed = try std.json.parseFromSlice(AppImage, std.testing.allocator, "{\"Name\":\"Minimal\"}", .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Minimal", parsed.value.Name);
    try std.testing.expectEqualStrings("", parsed.value.DesktopName);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.SizeOnDisk);
    try std.testing.expectEqual(UpdateType.None, parsed.value.UpdateType);
    try std.testing.expect(parsed.value.RepoOwner == null);
    try std.testing.expect(parsed.value.Path == null);
}

test "AppImageUpdate decodes from wire-format JSON" {
    const json =
        \\{"Name":"Blender","Version":"4.3.0","DownloadUrl":"https://example.org/blender.AppImage","IsUpdateAvailable":true}
    ;
    const parsed = try std.json.parseFromSlice(AppImageUpdate, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Blender", parsed.value.Name);
    try std.testing.expectEqualStrings("4.3.0", parsed.value.Version);
    try std.testing.expect(parsed.value.IsUpdateAvailable);
}

test "UpdateType.toCliString matches the spelling accepted by the CLI" {
    try std.testing.expectEqualStrings("None", UpdateType.None.toCliString());
    try std.testing.expectEqualStrings("StaticUrl", UpdateType.StaticUrl.toCliString());
    try std.testing.expectEqualStrings("GitHub", UpdateType.GitHub.toCliString());
    try std.testing.expectEqualStrings("GitLab", UpdateType.GitLab.toCliString());
    try std.testing.expectEqualStrings("Codeberg", UpdateType.Codeberg.toCliString());
    try std.testing.expectEqualStrings("Forgejo", UpdateType.Forgejo.toCliString());
}
