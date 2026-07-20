const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const flatpak = @import("../models/flatpak.zig");

pub const FlatpakObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        name: [:0]const u8,
        version: [:0]const u8,
        remotes: [:0]const u8,
        id: [:0]const u8,
        kind: flatpak.FlatpakKind,

        installed_size: i64,
        installed_level: flatpak.InstallLevel,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakObject",
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
        p.remotes = "";
        p.id = "";
        p.installed_size = 0;
        p.installed_level = flatpak.InstallLevel.system;
        p.kind = flatpak.FlatpakKind.app;
    }

    pub fn new(
        arena: std.mem.Allocator,
        f: flatpak.Flatpak,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.name = arena.dupeZ(u8, f.Name) catch "";
        p.version = arena.dupeZ(u8, f.Version) catch "";
        p.installed_level = f.InstallLevel;
        p.installed_size = f.InstalledSize;
        p.remotes = arena.dupeZ(u8, f.Remote) catch "";
        p.id = arena.dupeZ(u8, f.Id) catch "";
        p.kind = f.Kind;

        return self;
    }

    pub fn getName(self: *Self) [:0]const u8 {
        return self.priv().name;
    }
    pub fn getVersion(self: *Self) [:0]const u8 {
        return self.priv().version;
    }

    pub fn getInstalledSize(self: *Self) i64 {
        return self.priv().installed_size;
    }

    pub fn getInstallLevel(self: *Self) flatpak.InstallLevel {
        return self.priv().installed_level;
    }

    pub fn getRemotes(self: *Self) [:0]const u8 {
        return self.priv().remotes;
    }

    pub fn getId(self: *Self) [:0]const u8 {
        return self.priv().id;
    }

    pub fn getKind(self: *Self) flatpak.FlatpakKind {
        return self.priv().kind;
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
