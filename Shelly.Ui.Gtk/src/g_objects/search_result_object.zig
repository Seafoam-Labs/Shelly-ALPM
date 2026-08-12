const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const search = @import("../models/search_result.zig");
const AurPackage = @import("../models/aur_package.zig").AurPackage;
const Hit = @import("../models/flatpak.zig").Hit;

pub const SearchResultObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        result: search.SearchResult,
        selected: bool = false,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellySearchResultObject",
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
        p.selected = false;
        p.result = .{};
    }

    pub fn new(result: search.SearchResult) error{OutOfMemory}!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.as(gobject.Object).unref();

        const arena = try std.heap.c_allocator.create(std.heap.ArenaAllocator);
        errdefer std.heap.c_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();

        const p = self.priv();
        p.result = try cloneResult(arena.allocator(), result);
        p.arena = arena;
        return self;
    }

    pub fn getResult(self: *const Self) *const search.SearchResult {
        return &@constCast(self).priv().result;
    }

    pub fn getSource(self: *const Self) search.Source {
        return self.getResult().source;
    }

    pub fn getName(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().name);
    }

    pub fn getInstallTarget(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().install_target);
    }

    pub fn getVersion(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().version);
    }

    pub fn getDescription(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().description);
    }

    pub fn getRepository(self: *const Self) [:0]const u8 {
        return asZ(self.getResult().repository);
    }

    /// Full AUR record for the eventual detail pane, when source is .aur.
    pub fn getAurPackage(self: *const Self) ?*const AurPackage {
        const p = @constCast(self).priv();
        if (p.result.aur) |*value| return value;
        return null;
    }

    /// Full Flatpak hit for the eventual detail pane, when source is .flatpak.
    pub fn getFlatpakHit(self: *const Self) ?*const Hit {
        const p = @constCast(self).priv();
        if (p.result.flatpak) |*value| return value;
        return null;
    }

    pub fn isInstalled(self: *const Self) bool {
        return self.getResult().installed;
    }

    pub fn isOutOfDate(self: *const Self) bool {
        return self.getResult().out_of_date;
    }

    pub fn isVerified(self: *const Self) bool {
        return self.getResult().verified;
    }

    pub fn isSelected(self: *const Self) bool {
        return @constCast(self).priv().selected;
    }

    pub fn setSelected(self: *Self, selected: bool) void {
        self.priv().selected = selected;
    }

    pub fn toggleSelected(self: *Self) bool {
        const p = self.priv();
        p.selected = !p.selected;
        return p.selected;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn cloneResult(allocator: std.mem.Allocator, source: search.SearchResult) !search.SearchResult {
        return search.clone(allocator, source);
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

test "search GObject owns result data" {
    const object = try SearchResultObject.new(.{
        .source = .aur,
        .name = "polymc",
        .install_target = "polymc",
        .version = "7.1-2",
        .description = "Minecraft launcher with the ability to manage multiple instances",
        .repository = "AUR",
        .out_of_date = true,
        .aur = .{
            .Id = 2160856,
            .Name = "polymc",
            .PackageBaseId = 174947,
            .PackageBase = "polymc",
            .Version = "7.1-2",
            .Description = "Minecraft launcher with the ability to manage multiple instances",
            .Url = "https://github.com/PolyMC/PolyMC",
            .NumVotes = 74,
            .Popularity = 1.766204,
            .Maintainer = "LennyLennington",
            .FirstSubmitted = 1641934424,
            .LastModified = 1783993900,
            .UrlPath = "/cgit/aur.git/snapshot/polymc.tar.gz",
            .Depends = &.{ "java-runtime", "libgl" },
            .License = &.{"GPL3"},
        },
    });
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqual(search.Source.aur, object.getSource());
    try std.testing.expectEqualStrings("polymc", object.getName());
    try std.testing.expectEqualStrings("polymc", object.getInstallTarget());
    try std.testing.expectEqualStrings("7.1-2", object.getVersion());
    try std.testing.expectEqualStrings("AUR", object.getRepository());
    try std.testing.expect(object.isOutOfDate());
    try std.testing.expect(!object.isInstalled());
    try std.testing.expect(!object.isSelected());

    const aur = object.getAurPackage().?;
    try std.testing.expectEqual(@as(u32, 74), aur.NumVotes);
    try std.testing.expectEqualStrings("LennyLennington", aur.Maintainer.?);
    try std.testing.expectEqualStrings("libgl", aur.Depends.?[1]);
    try std.testing.expect(object.getFlatpakHit() == null);
}

test "search GObject keeps flatpak hit data" {
    const object = try SearchResultObject.new(.{
        .source = .flatpak,
        .name = "Firefox",
        .install_target = "org.mozilla.firefox",
        .description = "Fast, Private & Safe Web Browser",
        .repository = "flathub",
        .verified = true,
        .flatpak = .{
            .name = "Firefox",
            .id = "org.mozilla.firefox",
            .summary = "Fast, Private & Safe Web Browser",
            .description = "Firefox is a browser",
            .remote = "flathub",
            .developer_name = "Mozilla",
            .project_license = "MPL-2.0",
            .verification_verified = true,
            .download_size = 90000000,
            .installed_size = 300000000,
            .keywords = &.{ "browser", "web" },
        },
    });
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqual(search.Source.flatpak, object.getSource());
    try std.testing.expect(object.isVerified());
    try std.testing.expect(object.getAurPackage() == null);

    const hit = object.getFlatpakHit().?;
    try std.testing.expectEqualStrings("org.mozilla.firefox", hit.id);
    try std.testing.expectEqualStrings("Mozilla", hit.developer_name);
    try std.testing.expectEqual(@as(i64, 90000000), hit.download_size);
    try std.testing.expectEqualStrings("browser", hit.keywords[0]);
}

test "search GObject handles defaults" {
    const object = try SearchResultObject.new(.{});
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqual(search.Source.standard, object.getSource());
    try std.testing.expectEqualStrings("", object.getName());
    try std.testing.expectEqualStrings("", object.getDescription());
}
