const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const flatpak = @import("../models/flatpak.zig");

pub const AppstreamAppObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        app: flatpak.AppstreamApp,
        membership: Membership = .{},
        permissions: []const [:0]const u8,
        var offset: c_int = 0;
    };

    pub const Collection = enum { trending, popular, recently_updated, recently_added };
    pub const Membership = std.EnumSet(Collection);

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAppstreamAppObject",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const p = self.priv();
        p.arena = null;
        p.permissions = &.{};
        p.membership = .{};
        p.app = .{};
    }

    pub fn new(app: flatpak.AppstreamApp) error{OutOfMemory}!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.as(gobject.Object).unref();

        const arena = try std.heap.c_allocator.create(std.heap.ArenaAllocator);
        errdefer std.heap.c_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();

        const p = self.priv();
        p.app = try cloneApp(arena.allocator(), app);
        p.arena = arena;
        return self;
    }

    pub fn getApp(self: *const Self) *flatpak.AppstreamApp {
        return &@constCast(self).priv().app;
    }

    pub fn getId(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().Id);
    }

    pub fn getName(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().Name);
    }

    pub fn getSummary(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().Summary);
    }

    pub fn getDescription(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().Description);
    }

    pub fn getType(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().Type);
    }

    pub fn getProjectLicense(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().ProjectLicense);
    }

    pub fn getDeveloperName(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().DeveloperName);
    }

    pub fn getCategories(self: *const Self) []const []const u8 {
        return self.getApp().Categories;
    }

    pub fn getKeywords(self: *const Self) []const []const u8 {
        return self.getApp().Keywords;
    }

    pub fn getIcons(self: *const Self) []const flatpak.AppstreamIcon {
        return self.getApp().Icons;
    }

    pub fn getScreenshots(self: *const Self) []const flatpak.AppstreamScreenshot {
        return self.getApp().Screenshots;
    }

    pub fn getReleases(self: *const Self) []const flatpak.AppstreamRelease {
        return self.getApp().Releases;
    }

    pub fn getUrls(self: *const Self) *const std.json.ArrayHashMap([]const u8) {
        return &self.getApp().Urls;
    }

    pub fn isVerified(self: *const Self) bool {
        return self.getApp().IsVerified;
    }

    pub fn getVerificationMethod(self: *const Self) [:0]const u8 {
        return asZ(self.getApp().VerificationMethod);
    }

    pub fn getRemotes(self: *const Self) []const flatpak.Remote {
        return self.getApp().Remotes;
    }

    pub fn getExtends(self: *const Self) ?[:0]const u8 {
        return if (self.getApp().Extends) |value| asZ(value) else null;
    }

    pub fn getAddons(self: *const Self) []const flatpak.AppstreamApp {
        return self.getApp().Addons;
    }

    pub fn getMembership(self: *const Self) Membership {
        return @constCast(self).priv().membership;
    }

    pub fn setMembership(self: *Self, membership: Membership) void {
        self.priv().membership = membership;
    }

    pub fn getPermissions(self: *Self) []const [:0]const u8 {
        const p = self.priv();

        return p.permissions;
    }

    pub fn isInstalled(self: *const Self) bool {
        return self.getApp().Installed;
    }

    pub fn setInstalled(self: *Self, installed: bool) void {
        self.getApp().Installed = installed;
    }

    pub fn setPermissions(self: *Self, permissions: []const []const u8) void {
        const p = self.priv();
        const arena = p.arena orelse return;
        const alloc = arena.allocator();

        const owned_perms = alloc.alloc([:0]const u8, permissions.len) catch return;
        for (permissions, 0..) |perm, i| {
            owned_perms[i] = alloc.dupeZ(u8, perm) catch "";
        }

        p.permissions = owned_perms;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn cloneApp(allocator: std.mem.Allocator, source: flatpak.AppstreamApp) !flatpak.AppstreamApp {
        var urls: std.json.ArrayHashMap([]const u8) = .{};
        var url_iterator = source.Urls.map.iterator();
        while (url_iterator.next()) |entry| {
            try urls.map.put(
                allocator,
                try allocator.dupeZ(u8, entry.key_ptr.*),
                try allocator.dupeZ(u8, entry.value_ptr.*),
            );
        }

        const icons = try allocator.alloc(flatpak.AppstreamIcon, source.Icons.len);
        for (source.Icons, 0..) |icon, index| {
            icons[index] = .{
                .Type = try allocator.dupeZ(u8, icon.Type),
                .Url = try allocator.dupeZ(u8, icon.Url),
                .Width = icon.Width,
                .Height = icon.Height,
                .Scale = icon.Scale,
            };
        }

        const screenshots = try allocator.alloc(flatpak.AppstreamScreenshot, source.Screenshots.len);
        for (source.Screenshots, 0..) |screenshot, index| {
            const images = try allocator.alloc(flatpak.AppstreamImage, screenshot.Images.len);
            for (screenshot.Images, 0..) |image, image_index| {
                images[image_index] = .{
                    .Type = try allocator.dupeZ(u8, image.Type),
                    .Url = try allocator.dupeZ(u8, image.Url),
                    .Width = image.Width,
                    .Height = image.Height,
                };
            }
            screenshots[index] = .{
                .Caption = try allocator.dupeZ(u8, screenshot.Caption),
                .IsDefault = screenshot.IsDefault,
                .Images = images,
            };
        }

        const releases = try allocator.alloc(flatpak.AppstreamRelease, source.Releases.len);
        for (source.Releases, 0..) |release, index| {
            releases[index] = .{
                .Version = try allocator.dupeZ(u8, release.Version),
                .Type = try allocator.dupeZ(u8, release.Type),
                .Timestamp = release.Timestamp,
                .Description = try allocator.dupeZ(u8, release.Description),
            };
        }

        const remotes = try allocator.alloc(flatpak.Remote, source.Remotes.len);
        for (source.Remotes, 0..) |remote, index| {
            remotes[index] = .{
                .Name = try allocator.dupeZ(u8, remote.Name),
                .Url = try allocator.dupeZ(u8, remote.Url),
                .Scope = remote.Scope,
            };
        }

        const addons = try allocator.alloc(flatpak.AppstreamApp, source.Addons.len);
        for (source.Addons, 0..) |addon, index| addons[index] = try cloneApp(allocator, addon);

        return .{
            .Id = try allocator.dupeZ(u8, source.Id),
            .Name = try allocator.dupeZ(u8, source.Name),
            .Summary = try allocator.dupeZ(u8, source.Summary),
            .Description = try allocator.dupeZ(u8, source.Description),
            .Type = try allocator.dupeZ(u8, source.Type),
            .ProjectLicense = try allocator.dupeZ(u8, source.ProjectLicense),
            .DeveloperName = try allocator.dupeZ(u8, source.DeveloperName),
            .Categories = try cloneStrings(allocator, source.Categories),
            .Keywords = try cloneStrings(allocator, source.Keywords),
            .Icons = icons,
            .Screenshots = screenshots,
            .Releases = releases,
            .Urls = urls,
            .IsVerified = source.IsVerified,
            .VerificationMethod = try allocator.dupeZ(u8, source.VerificationMethod),
            .Remotes = remotes,
            .Extends = if (source.Extends) |value| try allocator.dupeZ(u8, value) else null,
            .Addons = addons,
            .Installed = source.Installed,
        };
    }

    fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
        const result = try allocator.alloc([]const u8, source.len);
        for (source, 0..) |value, index| result[index] = try allocator.dupeZ(u8, value);
        return result;
    }

    fn asZ(value: []const u8) [:0]const u8 {
        return value.ptr[0..value.len :0];
    }

    fn finalize(object: *gobject.Object) callconv(.c) void {
        const self = gobject.ext.cast(Self, object) orelse {
            Class.parent.f_finalize.?(object);
            return;
        };
        const p = self.priv();
        if (p.arena) |arena| {
            arena.deinit();
            std.heap.c_allocator.destroy(arena);
            p.arena = null;
        }
        Class.parent.f_finalize.?(object);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const object_class = class.as(gobject.Object.Class);
            object_class.f_finalize = &finalize;
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};

test "AppStream GObject owns nested app data" {
    var urls: std.json.ArrayHashMap([]const u8) = .{};
    try urls.map.put(std.testing.allocator, "homepage", "https://example.test");
    defer urls.deinit(std.testing.allocator);

    const source = flatpak.AppstreamApp{
        .Id = "org.example.App",
        .Name = "Example",
        .Summary = "Summary",
        .Categories = &.{"Utility"},
        .Icons = &.{.{ .Type = "cached", .Url = "icon.png", .Width = 64, .Height = 64 }},
        .Urls = urls,
        .IsVerified = true,
        .Remotes = &.{.{ .Name = "flathub", .Url = "https://flathub.org", .Scope = .user }},
        .Addons = &.{.{ .Id = "org.example.App.Locale", .Name = "Translations" }},
    };

    const object = try AppstreamAppObject.new(source);
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("org.example.App", object.getId());
    try std.testing.expectEqualStrings("Utility", object.getCategories()[0]);
    try std.testing.expectEqualStrings("icon.png", object.getIcons()[0].Url);
    try std.testing.expectEqualStrings("https://example.test", object.getUrls().map.get("homepage").?);
    try std.testing.expect(object.isVerified());
    try std.testing.expectEqual(flatpak.InstallLevel.user, object.getRemotes()[0].Scope);
    try std.testing.expectEqualStrings("org.example.App.Locale", object.getAddons()[0].Id);
}

test "AppStream GObject accepts empty metadata" {
    const object = try AppstreamAppObject.new(.{});
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("", object.getName());
    try std.testing.expectEqual(@as(usize, 0), object.getScreenshots().len);
    try std.testing.expect(object.getExtends() == null);
}
