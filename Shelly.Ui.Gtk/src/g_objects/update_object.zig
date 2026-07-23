const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;

pub const UpdateSource = enum {
    package,
    aur,
    flatpak,

    pub fn label(self: UpdateSource) [:0]const u8 {
        return switch (self) {
            .package => "System",
            .aur => "AUR",
            .flatpak => "Flatpak",
        };
    }

    pub fn icon(self: UpdateSource) [:0]const u8 {
        return switch (self) {
            .package => "package-x-generic-symbolic",
            .aur => "system-software-install-symbolic",
            .flatpak => "application-x-executable-symbolic",
        };
    }
};

pub const UpdateObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        source: UpdateSource,
        name: [:0]const u8,
        description: [:0]const u8,
        old_version: [:0]const u8,
        new_version: [:0]const u8,
        size: [:0]const u8,
        selected: bool,
        enabled: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyUpdateObject",
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
        p.source = .package;
        p.name = "";
        p.description = "";
        p.old_version = "";
        p.new_version = "";
        p.size = "";
        p.selected = true;
        p.enabled = true;
    }

    pub fn new(allocator: std.mem.Allocator, source: UpdateSource, name: []const u8, description: []const u8, old_version: []const u8, new_version: []const u8, size: []const u8) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.source = source;
        p.name = allocator.dupeZ(u8, name) catch "";
        p.description = allocator.dupeZ(u8, description) catch "";
        p.old_version = allocator.dupeZ(u8, old_version) catch "";
        p.new_version = allocator.dupeZ(u8, new_version) catch "";
        p.size = allocator.dupeZ(u8, size) catch "";
        return self;
    }

    pub fn getSource(self: *Self) UpdateSource {
        return self.priv().source;
    }

    pub fn getName(self: *Self) [:0]const u8 {
        return self.priv().name;
    }

    pub fn getDescription(self: *Self) [:0]const u8 {
        return self.priv().description;
    }

    pub fn getOldVersion(self: *Self) [:0]const u8 {
        return self.priv().old_version;
    }

    pub fn getNewVersion(self: *Self) [:0]const u8 {
        return self.priv().new_version;
    }

    pub fn getSize(self: *Self) [:0]const u8 {
        return self.priv().size;
    }

    pub fn isSelected(self: *Self) bool {
        return self.priv().selected;
    }

    pub fn isEnabled(self: *Self) bool {
        return self.priv().enabled;
    }

    pub fn setSelected(self: *Self, selected: bool) void {
        self.priv().selected = selected;
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        const p = self.priv();
        p.enabled = enabled;
        p.selected = enabled;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(_: *Class) callconv(.c) void {}
    };
};
