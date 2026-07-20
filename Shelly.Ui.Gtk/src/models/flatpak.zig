const std = @import("std");

pub const InstallLevel = enum(u8) {
    system = 0,
    user = 1,
};

pub const Remote = struct {
    Name: []const u8 = "",
    Url: []const u8 = "",
    Scope: InstallLevel = .system,
};

pub const FlatpakKind = enum(u8) {
    app = 0,
    runtime = 1,
};

pub const Flatpak = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Version: []const u8 = "",
    Remote: []const u8 = "",
    Kind: FlatpakKind = .app,
    InstalledSize: i64 = 0,
    InstallLevel: InstallLevel = .system,
};

pub const FlatpakRemoteInfo = struct {
    DownloadSize: i64 = 0,
    InstalledSize: i64 = 0,
    Permissions: []const []const u8 = &.{},
};

pub const AppstreamIcon = struct {
    Type: []const u8 = "",
    Url: []const u8 = "",
    Width: i32 = 0,
    Height: i32 = 0,
    Scale: i32 = 1,
};

pub const AppstreamImage = struct {
    Type: []const u8 = "",
    Url: []const u8 = "",
    Width: i32 = 0,
    Height: i32 = 0,
};

pub const AppstreamScreenshot = struct {
    Caption: []const u8 = "",
    IsDefault: bool = false,
    Images: []const AppstreamImage = &.{},
};

pub const AppstreamRelease = struct {
    Version: []const u8 = "",
    Type: []const u8 = "",
    Timestamp: i64 = 0,
    Description: []const u8 = "",
};

pub const AppstreamApp = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Summary: []const u8 = "",
    Description: []const u8 = "",
    Type: []const u8 = "",
    ProjectLicense: []const u8 = "",
    DeveloperName: []const u8 = "",
    Categories: []const []const u8 = &.{},
    Keywords: []const []const u8 = &.{},
    Icons: []const AppstreamIcon = &.{},
    Screenshots: []const AppstreamScreenshot = &.{},
    Releases: []const AppstreamRelease = &.{},
    Urls: std.json.ArrayHashMap([]const u8) = .{},
    IsVerified: bool = false,
    VerificationMethod: []const u8 = "",
    Remotes: []const Remote = &.{},
    Extends: ?[]const u8 = null,
    Addons: []const AppstreamApp = &.{},
};

test "parse AppStream app metadata" {
    const json =
        \\{"Id":"org.example.App","Name":"Example","Summary":"A useful app","Description":"Long description","Type":"desktop-application","ProjectLicense":"MIT","DeveloperName":"Example Org","Categories":["Utility"],"Keywords":["example","utility"],"Icons":[{"Type":"cached","Url":"icons/example.png","Width":128,"Height":128,"Scale":2}],"Screenshots":[{"Caption":"Main window","IsDefault":true,"Images":[{"Type":"source","Url":"https://example.test/screenshot.png","Width":1920,"Height":1080}]}],"Releases":[{"Version":"1.2.3","Type":"stable","Timestamp":1735689600,"Description":"First release"}],"Urls":{"homepage":"https://example.test"},"IsVerified":true,"VerificationMethod":"remote","Remotes":[{"Name":"flathub","Url":"https://flathub.org/repo/flathub.flatpakrepo","Scope":1}],"Extends":null,"Addons":[{"Id":"org.example.App.Locale","Name":"Translations"}]}
    ;
    const parsed = try std.json.parseFromSlice(AppstreamApp, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("org.example.App", parsed.value.Id);
    try std.testing.expectEqualStrings("Example", parsed.value.Name);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.Icons.len);
    try std.testing.expectEqual(@as(i32, 2), parsed.value.Icons[0].Scale);
    try std.testing.expect(parsed.value.Screenshots[0].IsDefault);
    try std.testing.expectEqual(@as(i64, 1735689600), parsed.value.Releases[0].Timestamp);
    try std.testing.expectEqualStrings("https://example.test", parsed.value.Urls.map.get("homepage").?);
    try std.testing.expectEqual(InstallLevel.user, parsed.value.Remotes[0].Scope);
    try std.testing.expect(parsed.value.Extends == null);
    try std.testing.expectEqualStrings("org.example.App.Locale", parsed.value.Addons[0].Id);
}

test "AppStream app metadata defaults missing optional fields" {
    const parsed = try std.json.parseFromSlice(AppstreamApp, std.testing.allocator, "{\"Id\":\"org.example.Minimal\"}", .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("org.example.Minimal", parsed.value.Id);
    try std.testing.expectEqualStrings("", parsed.value.Name);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.Icons.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.Urls.map.count());
    try std.testing.expect(!parsed.value.IsVerified);
    try std.testing.expect(parsed.value.Extends == null);
}

test "parse Flatpak remote info metadata" {
    const json =
        \\{"DownloadSize":150997939,"InstalledSize":470429696,"Permissions":["Context=shared:network","Context=sockets:wayland"]}
    ;
    const parsed = try std.json.parseFromSlice(FlatpakRemoteInfo, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 150997939), parsed.value.DownloadSize);
    try std.testing.expectEqual(@as(i64, 470429696), parsed.value.InstalledSize);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.Permissions.len);
}
