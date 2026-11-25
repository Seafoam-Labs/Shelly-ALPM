const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const models = @import("../models/fwupd.zig");
const enums = @import("../services/fwupd_enums.zig");

/// List-model wrapper for an updatable fwupd device. Strings are arena-owned
/// copies; the page must remove objects from the store before the arena dies.
pub const FirmwareDeviceObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    pub const Badge = struct {
        has_upgrade: bool = false,
        latest_version: []const u8 = "",
    };

    const Private = struct {
        device_id: [:0]const u8,
        name: [:0]const u8,
        vendor: [:0]const u8,
        summary: [:0]const u8,
        icon: [:0]const u8,
        version: [:0]const u8,
        version_lowest: [:0]const u8,
        latest_version: [:0]const u8,
        branch: [:0]const u8,
        guid: []const []const u8,
        flags: u64,
        problems: u64,
        update_state: enums.UpdateState,
        battery_level: u32,
        battery_threshold: u32,
        has_upgrade: bool,
        order: u32,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFirmwareDeviceObject",
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
        p.device_id = "";
        p.name = "";
        p.vendor = "";
        p.summary = "";
        p.icon = "";
        p.version = "";
        p.version_lowest = "";
        p.latest_version = "";
        p.branch = "";
        p.guid = &.{};
        p.flags = 0;
        p.problems = 0;
        p.update_state = .unknown;
        p.battery_level = enums.battery_level_invalid;
        p.battery_threshold = enums.battery_level_invalid;
        p.has_upgrade = false;
        p.order = 0;
    }

    pub fn new(allocator: std.mem.Allocator, device: models.Device, badge: Badge, order: u32) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.fill(allocator, device);
        self.setBadge(allocator, badge);
        self.priv().order = order;
        return self;
    }

    /// Replace the device fields in place (DeviceChanged); arena-owned copies.
    pub fn updateFromDevice(self: *Self, allocator: std.mem.Allocator, device: models.Device) void {
        self.fill(allocator, device);
    }

    fn fill(self: *Self, allocator: std.mem.Allocator, device: models.Device) void {
        const p = self.priv();
        p.device_id = allocator.dupeSentinel(u8, device.device_id, 0) catch p.device_id;
        p.name = allocator.dupeSentinel(u8, device.name, 0) catch p.name;
        p.vendor = allocator.dupeSentinel(u8, device.vendor, 0) catch p.vendor;
        p.summary = allocator.dupeSentinel(u8, device.summary, 0) catch p.summary;
        const icon = if (device.icon.len > 0) device.icon[0] else "";
        p.icon = allocator.dupeSentinel(u8, icon, 0) catch p.icon;
        p.version = allocator.dupeSentinel(u8, device.version, 0) catch p.version;
        p.version_lowest = allocator.dupeSentinel(u8, device.version_lowest, 0) catch p.version_lowest;
        p.branch = allocator.dupeSentinel(u8, device.branch, 0) catch p.branch;
        p.guid = dupeStrv(allocator, device.guid) catch p.guid;
        p.flags = device.flags;
        p.problems = device.problems;
        p.update_state = device.update_state;
        p.battery_level = device.battery_level;
        p.battery_threshold = device.battery_threshold;
    }

    pub fn setBadge(self: *Self, allocator: std.mem.Allocator, badge: Badge) void {
        const p = self.priv();
        p.has_upgrade = badge.has_upgrade;
        p.latest_version = allocator.dupeSentinel(u8, badge.latest_version, 0) catch p.latest_version;
    }

    fn dupeStrv(allocator: std.mem.Allocator, strv: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
        const out = try allocator.alloc([]const u8, strv.len);
        for (out, strv) |*slot, s| slot.* = try allocator.dupe(u8, s);
        return out;
    }

    /// Dedupe for noisy DeviceChanged signals: same id + version + flags +
    /// problems + update state means no UI-relevant change (models.dedupeDeviceChanged).
    pub fn isSameState(self: *Self, device: models.Device) bool {
        const p = self.priv();
        return std.mem.eql(u8, p.device_id, device.device_id) and
            std.mem.eql(u8, p.version, device.version) and
            p.flags == device.flags and
            p.problems == device.problems and
            p.update_state == device.update_state;
    }

    pub fn getDeviceId(self: *Self) [:0]const u8 {
        return self.priv().device_id;
    }

    pub fn getName(self: *Self) [:0]const u8 {
        return self.priv().name;
    }

    pub fn getVendor(self: *Self) [:0]const u8 {
        return self.priv().vendor;
    }

    pub fn getSummary(self: *Self) [:0]const u8 {
        return self.priv().summary;
    }

    pub fn getIcon(self: *Self) [:0]const u8 {
        return self.priv().icon;
    }

    pub fn getVersion(self: *Self) [:0]const u8 {
        return self.priv().version;
    }

    pub fn getVersionLowest(self: *Self) [:0]const u8 {
        return self.priv().version_lowest;
    }

    pub fn getLatestVersion(self: *Self) [:0]const u8 {
        return self.priv().latest_version;
    }

    pub fn getBranch(self: *Self) [:0]const u8 {
        return self.priv().branch;
    }

    pub fn getGuid(self: *Self) []const []const u8 {
        return self.priv().guid;
    }

    pub fn getFlags(self: *Self) u64 {
        return self.priv().flags;
    }

    pub fn getProblems(self: *Self) u64 {
        return self.priv().problems;
    }

    pub fn getUpdateState(self: *Self) enums.UpdateState {
        return self.priv().update_state;
    }

    pub fn getBatteryLevel(self: *Self) u32 {
        return self.priv().battery_level;
    }

    pub fn getBatteryThreshold(self: *Self) u32 {
        return self.priv().battery_threshold;
    }

    pub fn hasUpgrade(self: *Self) bool {
        return self.priv().has_upgrade;
    }

    pub fn getOrder(self: *Self) u32 {
        return self.priv().order;
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

test "firmware device object copies fields and badge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const device = models.Device{
        .device_id = "dev1",
        .name = "System Firmware",
        .vendor = "Acme",
        .summary = "UEFI ESRT",
        .icon = &.{ "computer", "ac-adapter" },
        .version = "1.2.3",
        .version_lowest = "1.0.0",
        .branch = "main",
        .guid = &.{ "guid-a", "guid-b" },
        .flags = enums.DeviceFlags.updatable | enums.DeviceFlags.affects_fde,
        .problems = 1,
        .update_state = .needs_reboot,
        .battery_level = 80,
        .battery_threshold = 50,
    };
    const object = FirmwareDeviceObject.new(arena.allocator(), device, .{ .has_upgrade = true, .latest_version = "1.2.4" }, 3);
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("dev1", object.getDeviceId());
    try std.testing.expectEqualStrings("System Firmware", object.getName());
    try std.testing.expectEqualStrings("computer", object.getIcon());
    try std.testing.expectEqualStrings("1.2.3", object.getVersion());
    try std.testing.expectEqualStrings("1.0.0", object.getVersionLowest());
    try std.testing.expectEqualStrings("1.2.4", object.getLatestVersion());
    try std.testing.expect(object.hasUpgrade());
    try std.testing.expectEqual(@as(u32, 3), object.getOrder());
    try std.testing.expectEqual(@as(usize, 2), object.getGuid().len);
    try std.testing.expectEqualStrings("guid-b", object.getGuid()[1]);
    try std.testing.expectEqual(enums.UpdateState.needs_reboot, object.getUpdateState());
    try std.testing.expectEqual(@as(u32, 80), object.getBatteryLevel());
}

test "firmware device object dedupes equal state and detects changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const device = models.Device{ .device_id = "dev1", .version = "1.0", .flags = 2, .problems = 0, .update_state = .success };
    const object = FirmwareDeviceObject.new(arena.allocator(), device, .{}, 0);
    defer object.as(gobject.Object).unref();

    try std.testing.expect(object.isSameState(device));
    try std.testing.expect(!object.isSameState(.{ .device_id = "dev2", .version = "1.0", .flags = 2 }));
    try std.testing.expect(!object.isSameState(.{ .device_id = "dev1", .version = "1.1", .flags = 2 }));
    try std.testing.expect(!object.isSameState(.{ .device_id = "dev1", .version = "1.0", .flags = 2, .problems = 4 }));
    try std.testing.expect(!object.isSameState(.{ .device_id = "dev1", .version = "1.0", .flags = 2, .update_state = .pending }));

    const changed = models.Device{ .device_id = "dev1", .version = "1.1", .flags = 2, .update_state = .success };
    object.updateFromDevice(arena.allocator(), changed);
    try std.testing.expectEqualStrings("1.1", object.getVersion());
    try std.testing.expect(object.isSameState(changed));
}
