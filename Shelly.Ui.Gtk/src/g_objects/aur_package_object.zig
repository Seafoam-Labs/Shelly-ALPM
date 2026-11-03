const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const aur = @import("../models/aur_package.zig");

pub const AurPackageObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        package: aur.AurPackage,
        selected: bool = false,
        installed: bool = false,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAurPackageObject",
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
        p.installed = false;
        p.package = .{
            .Id = 0,
            .Name = "",
            .PackageBaseId = 0,
            .PackageBase = "",
            .Version = "",
            .UrlPath = "",
            .NumVotes = 0,
            .Popularity = 0.0,
            .OutOfDate = null,
            .Maintainer = null,
            .FirstSubmitted = 0,
            .LastModified = 0,
            .Depends = null,
            .MakeDepends = null,
            .OptDepends = null,
            .CheckDepends = null,
            .Conflicts = null,
            .Provides = null,
            .Replaces = null,
            .Groups = null,
            .License = null,
            .Keywords = null,
            .Explicit = false,
        };
    }

    pub fn new(package: aur.AurPackage) error{OutOfMemory}!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.as(gobject.Object).unref();

        const arena = try std.heap.c_allocator.create(std.heap.ArenaAllocator);
        errdefer std.heap.c_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();

        const p = self.priv();
        p.package = try clonePackage(arena.allocator(), package);
        p.arena = arena;
        return self;
    }

    pub fn getPackage(self: *const Self) *const aur.AurPackage {
        return &@constCast(self).priv().package;
    }

    pub fn getId(self: *const Self) u32 {
        return self.getPackage().Id;
    }

    pub fn getName(self: *const Self) [:0]const u8 {
        return asZ(self.getPackage().Name);
    }

    pub fn getPackageBase(self: *const Self) [:0]const u8 {
        return asZ(self.getPackage().PackageBase);
    }

    pub fn getPackageBaseId(self: *const Self) u32 {
        return self.getPackage().PackageBaseId;
    }

    pub fn getVersion(self: *const Self) [:0]const u8 {
        return asZ(self.getPackage().Version);
    }

    pub fn getDescription(self: *const Self) [:0]const u8 {
        return if (self.getPackage().Description) |value| asZ(value) else "";
    }

    pub fn getUrl(self: *const Self) ?[:0]const u8 {
        return if (self.getPackage().Url) |value| asZ(value) else null;
    }

    pub fn getUrlPath(self: *const Self) [:0]const u8 {
        return asZ(self.getPackage().UrlPath);
    }

    pub fn getMaintainer(self: *const Self) ?[:0]const u8 {
        return if (self.getPackage().Maintainer) |value| asZ(value) else null;
    }

    pub fn getNumVotes(self: *const Self) u32 {
        return self.getPackage().NumVotes;
    }

    pub fn getPopularity(self: *const Self) f64 {
        return self.getPackage().Popularity;
    }

    pub fn getOutOfDate(self: *const Self) ?i64 {
        return self.getPackage().OutOfDate;
    }

    pub fn isOutOfDate(self: *const Self) bool {
        return self.getPackage().OutOfDate != null;
    }

    pub fn getFirstSubmitted(self: *const Self) i64 {
        return self.getPackage().FirstSubmitted;
    }

    pub fn getLastModified(self: *const Self) i64 {
        return self.getPackage().LastModified;
    }

    pub fn getDepends(self: *const Self) []const []const u8 {
        return self.getPackage().Depends orelse &.{};
    }

    pub fn getMakeDepends(self: *const Self) []const []const u8 {
        return self.getPackage().MakeDepends orelse &.{};
    }

    pub fn getOptDepends(self: *const Self) []const []const u8 {
        return self.getPackage().OptDepends orelse &.{};
    }

    pub fn getCheckDepends(self: *const Self) []const []const u8 {
        return self.getPackage().CheckDepends orelse &.{};
    }

    pub fn getConflicts(self: *const Self) []const []const u8 {
        return self.getPackage().Conflicts orelse &.{};
    }

    pub fn getProvides(self: *const Self) []const []const u8 {
        return self.getPackage().Provides orelse &.{};
    }

    pub fn getReplaces(self: *const Self) []const []const u8 {
        return self.getPackage().Replaces orelse &.{};
    }

    pub fn getGroups(self: *const Self) []const []const u8 {
        return self.getPackage().Groups orelse &.{};
    }

    pub fn getLicense(self: *const Self) []const []const u8 {
        return self.getPackage().License orelse &.{};
    }

    pub fn getKeywords(self: *const Self) []const []const u8 {
        return self.getPackage().Keywords orelse &.{};
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

    pub fn isInstalled(self: *const Self) bool {
        return @constCast(self).priv().installed;
    }

    pub fn setInstalled(self: *Self, installed: bool) void {
        self.priv().installed = installed;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn clonePackage(allocator: std.mem.Allocator, source: aur.AurPackage) !aur.AurPackage {
        return .{
            .Id = source.Id,
            .Name = try allocator.dupeSentinel(u8, source.Name, 0),
            .PackageBaseId = source.PackageBaseId,
            .PackageBase = try allocator.dupeSentinel(u8, source.PackageBase, 0),
            .Version = try allocator.dupeSentinel(u8, source.Version, 0),
            .Description = if (source.Description) |value| try allocator.dupeSentinel(u8, value, 0) else null,
            .Url = if (source.Url) |value| try allocator.dupeSentinel(u8, value, 0) else null,
            .NumVotes = source.NumVotes,
            .Popularity = source.Popularity,
            .OutOfDate = source.OutOfDate,
            .Maintainer = if (source.Maintainer) |value| try allocator.dupeSentinel(u8, value, 0) else null,
            .FirstSubmitted = source.FirstSubmitted,
            .LastModified = source.LastModified,
            .UrlPath = try allocator.dupeSentinel(u8, source.UrlPath, 0),
            .Depends = try cloneOptionalStrings(allocator, source.Depends),
            .MakeDepends = try cloneOptionalStrings(allocator, source.MakeDepends),
            .OptDepends = try cloneOptionalStrings(allocator, source.OptDepends),
            .CheckDepends = try cloneOptionalStrings(allocator, source.CheckDepends),
            .Conflicts = try cloneOptionalStrings(allocator, source.Conflicts),
            .Provides = try cloneOptionalStrings(allocator, source.Provides),
            .Replaces = try cloneOptionalStrings(allocator, source.Replaces),
            .Groups = try cloneOptionalStrings(allocator, source.Groups),
            .License = try cloneOptionalStrings(allocator, source.License),
            .Keywords = try cloneOptionalStrings(allocator, source.Keywords),
        };
    }

    fn cloneOptionalStrings(
        allocator: std.mem.Allocator,
        source: ?[]const [:0]const u8,
    ) !?[]const [:0]const u8 {
        const values = source orelse return null;
        const result = try allocator.alloc([:0]const u8, values.len);
        for (values, 0..) |value, index| result[index] = try allocator.dupeSentinel(u8, value, 0);
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

test "AUR GObject owns package data" {
    const source = aur.AurPackage{
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
        .Depends = &.{ "java-runtime", "libgl", "qt6-base" },
        .License = &.{"GPL3"},
    };

    const object = try AurPackageObject.new(source);
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("polymc", object.getName());
    try std.testing.expectEqualStrings("7.1-2", object.getVersion());
    try std.testing.expectEqualStrings("LennyLennington", object.getMaintainer().?);
    try std.testing.expectEqual(@as(u32, 74), object.getNumVotes());
    try std.testing.expectEqualStrings("libgl", object.getDepends()[1]);
    try std.testing.expectEqualStrings("GPL3", object.getLicense()[0]);
    try std.testing.expect(!object.isOutOfDate());
    try std.testing.expect(!object.isSelected());
}

test "AUR GObject handles absent optional fields" {
    const object = try AurPackageObject.new(.{
        .Id = 1,
        .Name = "x",
        .PackageBaseId = 1,
        .PackageBase = "x",
        .Version = "1-1",
        .NumVotes = 0,
        .Popularity = 0,
        .FirstSubmitted = 0,
        .LastModified = 0,
        .UrlPath = "/x",
    });
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("", object.getDescription());
    try std.testing.expect(object.getMaintainer() == null);
    try std.testing.expectEqual(@as(usize, 0), object.getConflicts().len);
}
