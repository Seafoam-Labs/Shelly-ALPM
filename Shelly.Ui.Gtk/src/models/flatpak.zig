const std = @import("std");

pub const Category = enum {
    @"All Applications",
    Recommended,
    Verified,
    @"Most Wanted",
    @"Recently Added",
    @"Recently Updated",
    @"Audio & Video",
    Development,
    Education,
    Game,
    Graphics,
    Network,
    Office,
    Science,
    System,
    Utility,

    pub fn toString(self: Category) []const u8 {
        return switch (self) {
            .@"Audio & Video" => "AudioVideo",
            else => @tagName(self),
        };
    }

    pub fn toDisplayString(self: Category) [:0]const u8 {
        return switch (self) {
            else => @tagName(self),
        };
    }
};

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

pub const FlatpakSearchResponse = struct {
    hits: []Hit = &.{},
    query: []const u8 = "",
    hitsPerPage: u32 = 0,
    page: u32 = 0,
    totalPages: u32 = 0,
    totalHits: u32 = 0,
};

pub const Hit = struct {
    name: []const u8 = "",
    keywords: []const []const u8 = &.{},
    summary: []const u8 = "",
    description: []const u8 = "",
    id: []const u8 = "",
    type: []const u8 = "",
    project_license: []const u8 = "",
    app_id: []const u8 = "",
    main_categories: []const []const u8 = &.{},
    developer_name: []const u8 = "",
    verification_verified: bool = false,
    verification_method: ?[]const u8 = null,
    remote: []const u8 = "",
    download_size: i64 = 0,
    installed_size: i64 = 0,
    permissions: []const []const u8 = &.{},

    pub fn clone(allocator: std.mem.Allocator, source: Hit) !Hit {
        return .{
            .name = try allocator.dupe(u8, source.name),
            .keywords = try cloneStrings(allocator, source.keywords),
            .summary = try allocator.dupe(u8, source.summary),
            .description = try allocator.dupe(u8, source.description),
            .id = try allocator.dupe(u8, source.id),
            .type = try allocator.dupe(u8, source.type),
            .project_license = try allocator.dupe(u8, source.project_license),
            .app_id = try allocator.dupe(u8, source.app_id),
            .main_categories = try cloneStrings(allocator, source.main_categories),
            .developer_name = try allocator.dupe(u8, source.developer_name),
            .verification_verified = source.verification_verified,
            .verification_method = if (source.verification_method) |value| try allocator.dupe(u8, value) else null,
            .remote = try allocator.dupe(u8, source.remote),
            .download_size = source.download_size,
            .installed_size = source.installed_size,
            .permissions = try cloneStrings(allocator, source.permissions),
        };
    }

    fn cloneStrings(
        allocator: std.mem.Allocator,
        source: []const []const u8,
    ) ![]const []const u8 {
        const result = try allocator.alloc([]const u8, source.len);
        for (source, 0..) |value, index| result[index] = try allocator.dupe(u8, value);
        return result;
    }
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
    Installed: bool = false,
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
