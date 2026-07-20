const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const Package = @import("../models/packages.zig").Package;
const gobject = bindings.gobject;

pub const PackageObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        name: [:0]const u8,
        version: [:0]const u8,
        repository: [:0]const u8,
        description: [:0]const u8,
        groups: []const [:0]const u8,
        installed_size: i64,
        installed: bool,
        selected: bool,

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
        p.name = "";
        p.version = "";
        p.repository = "";
        p.description = "";
        p.installed_size = 0;
        p.installed = false;
        p.selected = false;
    }

    pub fn new(arena: std.mem.Allocator, package: Package) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.name = arena.dupeZ(u8, package.Name) catch "";
        p.version = arena.dupeZ(u8, package.Version) catch "";
        p.repository = arena.dupeZ(u8, package.Repository) catch "";
        p.description = arena.dupeZ(u8, package.Description) catch "";
        p.installed_size = package.InstalledSize;
        p.installed = package.Installed;
        p.selected = false;

        if (arena.alloc([:0]const u8, package.Groups.len)) |g| {
            for (package.Groups, 0..) |src, i| {
                g[i] = arena.dupeZ(u8, src) catch "";
            }
            p.groups = g;
        } else |_| {
            p.groups = &.{};
        }

        return self;
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
    pub fn isSelected(self: *Self) bool {
        return self.priv().selected;
    }
    pub fn setSelected(self: *Self, v: bool) void {
        self.priv().selected = v;
    }

    pub fn getGroups(self: *Self) []const [:0]const u8 {
        return self.priv().groups;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(_: *Class) callconv(.c) void {}

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
