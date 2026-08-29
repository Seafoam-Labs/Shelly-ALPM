const DatabaseStatus = @This();
const std = @import("std");

pub const Presence = enum {
    unknown,
    exists,
    missing,
};

pub const Validation = enum {
    unchecked,
    valid,
    invalid,
};

presence: Presence = .unknown,
validation: Validation = .unchecked,

package_cache_loaded: bool = false,
group_cache_loaded: bool = false,

pub fn isUsable(self: DatabaseStatus) bool {
    return self.presence == .exists and
        self.validation == .valid;
}

pub fn markMissing(self: *DatabaseStatus) void {
    self.presence = .missing;
    self.validation = .unchecked;
    self.package_cache_loaded = false;
    self.group_cache_loaded = false;
}

pub fn markInvalid(self: *DatabaseStatus) void {
    self.presence = .exists;
    self.validation = .invalid;
    self.package_cache_loaded = false;
    self.group_cache_loaded = false;
}

pub fn markValid(self: *DatabaseStatus) void {
    self.presence = .exists;
    self.validation = .valid;
}

pub fn clearCaches(self: *DatabaseStatus) void {
    self.package_cache_loaded = false;
    self.group_cache_loaded = false;
}

test "DatabaseStatus defaults to unknown and unusable" {
    const status: DatabaseStatus = .{};

    try std.testing.expectEqual(Presence.unknown, status.presence);
    try std.testing.expectEqual(Validation.unchecked, status.validation);
    try std.testing.expect(!status.package_cache_loaded);
    try std.testing.expect(!status.group_cache_loaded);
    try std.testing.expect(!status.isUsable());
}

test "DatabaseStatus transitions preserve valid state invariants" {
    var status: DatabaseStatus = .{};

    status.markValid();
    try std.testing.expect(status.isUsable());

    status.package_cache_loaded = true;
    status.group_cache_loaded = true;
    status.clearCaches();
    try std.testing.expect(!status.package_cache_loaded);
    try std.testing.expect(!status.group_cache_loaded);

    status.package_cache_loaded = true;
    status.group_cache_loaded = true;
    status.markInvalid();
    try std.testing.expectEqual(Presence.exists, status.presence);
    try std.testing.expectEqual(Validation.invalid, status.validation);
    try std.testing.expect(!status.isUsable());
    try std.testing.expect(!status.package_cache_loaded);
    try std.testing.expect(!status.group_cache_loaded);

    status.markMissing();
    try std.testing.expectEqual(Presence.missing, status.presence);
    try std.testing.expectEqual(Validation.unchecked, status.validation);
}
