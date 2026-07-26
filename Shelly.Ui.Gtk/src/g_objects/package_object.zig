const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const Package = @import("../models/packages.zig").Package;
const gobject = bindings.gobject;

pub const PackageObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        arena: ?*std.heap.ArenaAllocator,
        name: [:0]const u8,
        version: [:0]const u8,
        repository: [:0]const u8,
        description: [:0]const u8,
        groups: []const [:0]const u8,
        explicit: bool,
        installed_size: i64,
        installed: bool,
        selected: bool,
        recommend_rank: i32,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPackageObject",
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
        p.name = "";
        p.version = "";
        p.repository = "";
        p.description = "";
        p.explicit = false;
        p.groups = &.{};
        p.installed_size = 0;
        p.installed = false;
        p.selected = false;
        p.recommend_rank = -1;
    }

    pub fn new(package: Package) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();

        const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return self;
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena;
        const a = arena.allocator();

        p.name = a.dupeZ(u8, package.Name) catch "";
        p.version = a.dupeZ(u8, package.Version) catch "";
        p.repository = a.dupeZ(u8, package.Repository) catch "";
        p.description = a.dupeZ(u8, package.Description) catch "";
        p.installed_size = package.InstalledSize;
        p.installed = package.Installed;
        p.explicit = package.Explicit;
        p.selected = false;
        p.recommend_rank = -1;

        if (a.alloc([:0]const u8, package.Groups.len)) |g| {
            for (package.Groups, 0..) |src, i| g[i] = a.dupeZ(u8, src) catch "";
            p.groups = g;
        } else |_| {
            p.groups = &.{};
        }
        return self;
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

    pub fn getName(self: *Self) [:0]const u8 {
        return self.priv().name;
    }
    pub fn getVersion(self: *Self) [:0]const u8 {
        return self.priv().version;
    }
    pub fn getRepository(self: *Self) [:0]const u8 {
        return self.priv().repository;
    }
    pub fn getDescription(self: *Self) [:0]const u8 {
        return self.priv().description;
    }
    pub fn getInstalledSize(self: *Self) i64 {
        return self.priv().installed_size;
    }
    pub fn isInstalled(self: *Self) bool {
        return self.priv().installed;
    }
    pub fn isExplicit(self: *Self) bool {
        return self.priv().explicit;
    }
    pub fn isSelected(self: *Self) bool {
        return self.priv().selected;
    }
    pub fn setSelected(self: *Self, v: bool) void {
        self.priv().selected = v;
    }

    pub fn getGroups(self: *Self) []const [:0]const u8 {
        return self.priv().groups;
    }

    pub fn getRecommendRank(self: *Self) i32 {
        return self.priv().recommend_rank;
    }

    pub fn setRecommendRank(self: *Self, rank: i32) void {
        self.priv().recommend_rank = rank;
    }

    pub fn isRecommended(self: *Self) bool {
        return self.priv().recommend_rank >= 0;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const object_class = gobject.ext.as(gobject.Object.Class, class);
            object_class.f_finalize = &finalize;
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
