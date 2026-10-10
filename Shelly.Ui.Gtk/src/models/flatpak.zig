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

/// One grouped permission row, as `Shelly.PackageManager` classified it and the
/// CLI serialised it. `concern`, `tier` and `state` are tag names kept as
/// strings on purpose: a concern this build has never seen still renders, as
/// `Other`, instead of failing the whole frame.
pub const PermissionRow = struct {
    concern: []const u8 = "",
    tier: []const u8 = "low",
    state: []const u8 = "granted",
    items: []const []const u8 = &.{},

    pub fn absent(self: PermissionRow) bool {
        return std.mem.eql(u8, self.state, "absent");
    }

    pub fn elevated(self: PermissionRow) bool {
        return std.mem.eql(u8, self.tier, "high");
    }

    pub fn middling(self: PermissionRow) bool {
        return std.mem.eql(u8, self.tier, "medium");
    }
};

/// A permission row shaped for the dialog. The title and the icon come from
/// `concern`, which is translated at render time; `detail` is the row's one
/// variable-length line, joined and null-terminated here so the widget code
/// never allocates and nothing is silently truncated.
pub const PermissionDisplay = struct {
    concern: []const u8 = "",
    tier: []const u8 = "low",
    absent: bool = false,
    detail: [:0]const u8 = "",

    pub fn elevated(self: PermissionDisplay) bool {
        return std.mem.eql(u8, self.tier, "high");
    }

    pub fn middling(self: PermissionDisplay) bool {
        return std.mem.eql(u8, self.tier, "medium");
    }
};

/// Joins each row's items into its detail line. `allocator` is expected to be an
/// arena that outlives every widget reading the result.
pub fn displayRows(
    allocator: std.mem.Allocator,
    rows: []const PermissionRow,
) ![]const PermissionDisplay {
    const result = try allocator.alloc(PermissionDisplay, rows.len);
    for (rows, result) |row, *target| {
        target.* = .{
            .concern = row.concern,
            .tier = row.tier,
            .absent = row.absent(),
            .detail = try joinZ(allocator, row.items, ", "),
        };
    }
    return result;
}

fn joinZ(allocator: std.mem.Allocator, values: []const []const u8, separator: []const u8) ![:0]const u8 {
    var total: usize = 0;
    for (values) |value| total += value.len;
    total += separator.len *| (if (values.len > 0) values.len - 1 else 0);

    const buffer = try allocator.alloc(u8, total + 1);
    var filled: usize = 0;
    for (values, 0..) |value, index| {
        if (index > 0) {
            @memcpy(buffer[filled .. filled + separator.len], separator);
            filled += separator.len;
        }
        @memcpy(buffer[filled .. filled + value.len], value);
        filled += value.len;
    }
    buffer[buffer.len - 1] = 0;
    return buffer[0..filled :0];
}

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
    /// Null when the CLI could not read the remote reference, which is not the
    /// same as an app that declares no permissions.
    permissions: ?[]const []const u8 = null,
    /// The same permissions grouped into rows. Null exactly when `permissions`
    /// is unusable, so the dialog can tell "none requested" from "not read".
    permission_rows: ?[]const PermissionRow = null,

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
            .permissions = if (source.permissions) |permissions| try cloneStrings(allocator, permissions) else null,
            .permission_rows = if (source.permission_rows) |rows| try cloneRows(allocator, rows) else null,
        };
    }

    pub fn cloneRows(allocator: std.mem.Allocator, source: []const PermissionRow) ![]const PermissionRow {
        const result = try allocator.alloc(PermissionRow, source.len);
        var prepared: usize = 0;
        errdefer {
            for (result[0..prepared]) |row| {
                for (row.items) |item| allocator.free(item);
                allocator.free(row.items);
            }
            allocator.free(result);
        }
        for (source, result) |row, *target| {
            target.* = .{
                .concern = try allocator.dupe(u8, row.concern),
                .tier = try allocator.dupe(u8, row.tier),
                .state = try allocator.dupe(u8, row.state),
                .items = try cloneStrings(allocator, row.items),
            };
            prepared += 1;
        }
        return result;
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

test "parse grouped Flatpak permission rows" {
    const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_always };

    // The frame the CLI's `search flatpak --json` writes for one app that
    // grants X11 and Wayland and asks for nothing else.
    const granted =
        \\{"hits":[{"name":"Editor","permission_rows":[{"concern":"display","tier":"high","state":"granted","items":["X11","Wayland"]},{"concern":"network","tier":"low","state":"absent","items":[]}]}],"query":"editor"}
    ;
    const parsed = try std.json.parseFromSlice(FlatpakSearchResponse, std.testing.allocator, granted, options);
    defer parsed.deinit();

    const rows = parsed.value.hits[0].permission_rows.?;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("display", rows[0].concern);
    try std.testing.expect(rows[0].elevated());
    try std.testing.expect(!rows[0].middling());
    try std.testing.expectEqualStrings("Wayland", rows[0].items[1]);
    try std.testing.expect(rows[1].absent());
    try std.testing.expectEqual(@as(usize, 0), rows[1].items.len);

    // A clone owns its strings, because the parsed frame is released as soon as
    // the worker's idle callback returns.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copy = try Hit.clone(arena.allocator(), parsed.value.hits[0]);
    try std.testing.expectEqualStrings("X11", copy.permission_rows.?[0].items[0]);

    const unread =
        \\{"hits":[{"name":"Editor","permission_rows":null}]}
    ;
    const unread_parsed = try std.json.parseFromSlice(FlatpakSearchResponse, std.testing.allocator, unread, options);
    defer unread_parsed.deinit();
    // Not read at all, which the dialog must not present as "requests nothing".
    try std.testing.expectEqual(null, unread_parsed.value.hits[0].permission_rows);

    const none =
        \\{"hits":[{"name":"Editor","permission_rows":[]}]}
    ;
    const none_parsed = try std.json.parseFromSlice(FlatpakSearchResponse, std.testing.allocator, none, options);
    defer none_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), none_parsed.value.hits[0].permission_rows.?.len);
}

test "permission rows join their items into one selectable line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rows = [_]PermissionRow{
        .{
            .concern = "files_user_dirs",
            .tier = "medium",
            .state = "granted",
            .items = &.{ "Downloads (read/write)", "Music (read-only)", "/mnt/data" },
        },
        .{ .concern = "network", .tier = "medium", .state = "granted", .items = &.{} },
        .{ .concern = "devices", .tier = "low", .state = "absent", .items = &.{} },
    };
    const display = try displayRows(allocator, &rows);
    try std.testing.expectEqualStrings(
        "Downloads (read/write), Music (read-only), /mnt/data",
        display[0].detail,
    );
    try std.testing.expectEqualStrings("", display[1].detail);
    try std.testing.expect(display[2].absent);
    try std.testing.expectEqualStrings("files_user_dirs", display[0].concern);
    try std.testing.expect(display[0].middling());
    try std.testing.expect(!display[1].elevated());
}
