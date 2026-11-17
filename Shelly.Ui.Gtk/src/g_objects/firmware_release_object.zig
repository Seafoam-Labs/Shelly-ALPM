const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gobject = bindings.gobject;
const models = @import("../models/fwupd.zig");
const enums = @import("../services/fwupd_enums.zig");

/// List-model wrapper for a firmware release. Strings are arena-owned copies,
/// so the page must empty the store before the arena dies.
pub const FirmwareReleaseObject = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gobject.Object;

    const Private = struct {
        version: [:0]const u8,
        summary: [:0]const u8,
        remote_id: [:0]const u8,
        checksum: [:0]const u8,
        filename: [:0]const u8,
        update_message: [:0]const u8,
        branch: [:0]const u8,
        locations: []const []const u8,
        uri: [:0]const u8,
        trust_flags: u64,
        urgency: enums.Urgency,
        size: u64,
        install_duration: u32,
        classification: models.Classification,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFirmwareReleaseObject",
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
        p.version = "";
        p.summary = "";
        p.remote_id = "";
        p.checksum = "";
        p.filename = "";
        p.update_message = "";
        p.branch = "";
        p.locations = &.{};
        p.uri = "";
        p.trust_flags = 0;
        p.urgency = .unknown;
        p.size = 0;
        p.install_duration = 0;
        p.classification = .other;
    }

    pub fn new(allocator: std.mem.Allocator, device: models.Device, release: models.Release) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const p = self.priv();
        p.version = allocator.dupeSentinel(u8, release.version, 0) catch "";
        p.summary = allocator.dupeSentinel(u8, release.summary, 0) catch "";
        p.remote_id = allocator.dupeSentinel(u8, release.remote_id, 0) catch "";
        p.checksum = allocator.dupeSentinel(u8, release.checksum, 0) catch "";
        p.filename = allocator.dupeSentinel(u8, release.filename, 0) catch "";
        p.update_message = allocator.dupeSentinel(u8, release.update_message, 0) catch "";
        p.branch = allocator.dupeSentinel(u8, release.branch, 0) catch "";
        p.locations = dupeStrv(allocator, release.locations) catch &.{};
        p.uri = allocator.dupeSentinel(u8, release.uri, 0) catch "";
        p.trust_flags = release.trust_flags;
        p.urgency = release.urgency;
        p.size = release.size;
        p.install_duration = release.install_duration;
        p.classification = models.classifyRelease(device, release);
        return self;
    }

    fn dupeStrv(allocator: std.mem.Allocator, strv: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
        const out = try allocator.alloc([]const u8, strv.len);
        for (out, strv) |*slot, s| slot.* = try allocator.dupe(u8, s);
        return out;
    }

    pub fn getVersion(self: *Self) [:0]const u8 {
        return self.priv().version;
    }

    pub fn getSummary(self: *Self) [:0]const u8 {
        return self.priv().summary;
    }

    pub fn getRemoteId(self: *Self) [:0]const u8 {
        return self.priv().remote_id;
    }

    pub fn getChecksum(self: *Self) [:0]const u8 {
        return self.priv().checksum;
    }

    pub fn getFilename(self: *Self) [:0]const u8 {
        return self.priv().filename;
    }

    pub fn getUpdateMessage(self: *Self) [:0]const u8 {
        return self.priv().update_message;
    }

    pub fn getBranch(self: *Self) [:0]const u8 {
        return self.priv().branch;
    }

    pub fn getLocations(self: *Self) []const []const u8 {
        return self.priv().locations;
    }

    /// Legacy single-URL key; `getLocations` wins when both are present.
    pub fn getUri(self: *Self) [:0]const u8 {
        return self.priv().uri;
    }

    pub fn getTrustFlags(self: *Self) u64 {
        return self.priv().trust_flags;
    }

    pub fn getUrgency(self: *Self) enums.Urgency {
        return self.priv().urgency;
    }

    pub fn getSize(self: *Self) u64 {
        return self.priv().size;
    }

    pub fn getInstallDuration(self: *Self) u32 {
        return self.priv().install_duration;
    }

    pub fn getClassification(self: *Self) models.Classification {
        return self.priv().classification;
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

test "firmware release object copies fields and classifies against the device" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const device = models.Device{ .device_id = "dev1", .version = "1.2.3" };
    const release = models.Release{
        .version = "1.2.4",
        .summary = "Fixes CVE-2026-1",
        .remote_id = "lvfs",
        .checksum = "aa,bb",
        .filename = "payload.cab",
        .locations = &.{"https://cdn.example.test/payload.cab"},
        .update_message = "Do not power off",
        .branch = "main",
        .trust_flags = enums.TrustFlags.is_upgrade | enums.TrustFlags.trusted_payload,
        .urgency = .high,
        .size = 4096,
        .install_duration = 60,
    };
    const object = FirmwareReleaseObject.new(arena.allocator(), device, release);
    defer object.as(gobject.Object).unref();

    try std.testing.expectEqualStrings("1.2.4", object.getVersion());
    try std.testing.expectEqualStrings("Fixes CVE-2026-1", object.getSummary());
    try std.testing.expectEqualStrings("lvfs", object.getRemoteId());
    try std.testing.expectEqualStrings("aa,bb", object.getChecksum());
    try std.testing.expectEqualStrings("payload.cab", object.getFilename());
    try std.testing.expectEqualStrings("Do not power off", object.getUpdateMessage());
    try std.testing.expectEqualStrings("https://cdn.example.test/payload.cab", object.getLocations()[0]);
    try std.testing.expectEqual(enums.Urgency.high, object.getUrgency());
    try std.testing.expectEqual(@as(u64, 4096), object.getSize());
    try std.testing.expectEqual(@as(u32, 60), object.getInstallDuration());
    try std.testing.expectEqual(models.Classification.upgrade, object.getClassification());

    const same = FirmwareReleaseObject.new(arena.allocator(), device, .{ .version = "1.2.3" });
    defer same.as(gobject.Object).unref();
    try std.testing.expectEqual(models.Classification.reinstall, same.getClassification());

    const blocked = FirmwareReleaseObject.new(arena.allocator(), device, .{
        .version = "1.2.4",
        .trust_flags = enums.TrustFlags.is_upgrade | enums.TrustFlags.blocked_version,
    });
    defer blocked.as(gobject.Object).unref();
    try std.testing.expectEqual(models.Classification.blocked, blocked.getClassification());
}