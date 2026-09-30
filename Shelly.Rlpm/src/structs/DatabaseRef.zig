//! A durable identifier, not a pointer into an Owner's growable database array.
const std = @import("std");

const DatabaseRef = @This();

pub const OwnerId = enum(u64) { _ };

/// archive identifies a plan's archive namespace, never a registered database.
pub const Id = enum(u64) { local = 0, archive = std.math.maxInt(u64), _ };
owner: OwnerId,
id: Id,

pub fn eql(a: DatabaseRef, b: DatabaseRef) bool {
    return a.owner == b.owner and a.id == b.id;
}
