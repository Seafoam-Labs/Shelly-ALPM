//! Borrowed registration input; Database owns a copy after registration.
const std = @import("std");
const SignaturePolicy = @import("SignaturePolicy.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");

const DatabaseConfiguration = @This();

database_name: []const u8,
/// null inherits the Owner's current default, including after reconfiguration.
signature_policy: ?SignaturePolicy = null,
servers: []const []const u8 = &.{},
cache_servers: []const []const u8 = &.{},
usage: DatabaseUsage = .{},

pub fn validate(self: DatabaseConfiguration) !void {
    const name = self.database_name;
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidDatabaseName;
    if (std.mem.eql(u8, name, "local")) return error.ReservedDatabaseName;
    for ([_][]const []const u8{ self.servers, self.cache_servers }) |urls| {
        for (urls) |url|
            if (url.len == 0 or std.mem.indexOfScalar(u8, url, 0) != null)
                return error.InvalidOption;
    }
}
