const std = @import("std");
const AppstreamAppObject = @import("../g_objects/appstream_app_object.zig").AppstreamAppObject;

/// the app ids in each flathub collection.
pub const FlathubCollections = struct {
    arena: std.heap.ArenaAllocator,
    sets: std.EnumArray(AppstreamAppObject.Collection, std.StringHashMapUnmanaged(void)) = .initFill(.empty),

    pub fn init(backing: std.mem.Allocator) FlathubCollections {
        return .{ .arena = .init(backing) };
    }

    pub fn deinit(self: *FlathubCollections) void {
        self.arena.deinit();
    }

    pub fn add(self: *FlathubCollections, which: AppstreamAppObject.Collection, ids: []const []const u8) error{OutOfMemory}!void {
        const alloc = self.arena.allocator();
        const set = self.sets.getPtr(which);
        for (ids) |id| try set.put(alloc, try alloc.dupe(u8, id), {});
    }

    pub fn isEmpty(self: *const FlathubCollections) bool {
        for (self.sets.values) |set| if (set.count() > 0) return false;
        return true;
    }

    /// takes over the collections of `old` that this one has no answer for.
    pub fn keepMissing(self: *FlathubCollections, old: *const FlathubCollections) error{OutOfMemory}!void {
        for (std.enums.values(AppstreamAppObject.Collection)) |which| {
            if (self.has(which)) continue;
            var ids = old.sets.getPtrConst(which).keyIterator();
            while (ids.next()) |id| try self.add(which, &.{id.*});
        }
    }

    pub fn has(self: *const FlathubCollections, which: AppstreamAppObject.Collection) bool {
        return self.sets.getPtrConst(which).count() > 0;
    }

    pub fn membership(self: *const FlathubCollections, app_id: []const u8) AppstreamAppObject.Membership {
        var found: AppstreamAppObject.Membership = .{};
        for (std.enums.values(AppstreamAppObject.Collection)) |which| {
            if (self.sets.getPtrConst(which).contains(app_id)) found.insert(which);
        }
        return found;
    }
};

const testing = std.testing;

test "membership lists every collection holding the app" {
    var collections: FlathubCollections = .init(testing.allocator);
    defer collections.deinit();
    try collections.add(.trending, &.{ "org.gimp.GIMP", "org.kde.krita" });
    try collections.add(.recently_added, &.{"org.gimp.GIMP"});

    const gimp = collections.membership("org.gimp.GIMP");
    try testing.expect(gimp.contains(.trending));
    try testing.expect(gimp.contains(.recently_added));
    try testing.expect(!gimp.contains(.popular));
    try testing.expectEqual(@as(usize, 0), collections.membership("org.example.None").count());
}

test "added ids outlive the caller's copy" {
    var collections: FlathubCollections = .init(testing.allocator);
    defer collections.deinit();
    var id = "org.gimp.GIMP".*;
    try collections.add(.popular, &.{&id});
    @memset(&id, 'x');
    try testing.expect(collections.membership("org.gimp.GIMP").contains(.popular));
}

test "a collection that did not answer keeps the older one" {
    var old: FlathubCollections = .init(testing.allocator);
    defer old.deinit();
    try old.add(.popular, &.{"org.gimp.GIMP"});
    try old.add(.trending, &.{"org.kde.krita"});

    var fresh: FlathubCollections = .init(testing.allocator);
    defer fresh.deinit();
    try fresh.add(.trending, &.{"org.example.New"});
    try fresh.keepMissing(&old);

    try testing.expect(fresh.membership("org.gimp.GIMP").contains(.popular));
    try testing.expect(fresh.membership("org.example.New").contains(.trending));
    try testing.expectEqual(@as(usize, 0), fresh.membership("org.kde.krita").count());
    try testing.expect(fresh.has(.popular));
    try testing.expect(!fresh.has(.recently_added));
}

test "isEmpty is true only until an id is added" {
    var collections: FlathubCollections = .init(testing.allocator);
    defer collections.deinit();
    try testing.expect(collections.isEmpty());
    try collections.add(.recently_updated, &.{});
    try testing.expect(collections.isEmpty());
    try collections.add(.recently_updated, &.{"org.gimp.GIMP"});
    try testing.expect(!collections.isEmpty());
}
