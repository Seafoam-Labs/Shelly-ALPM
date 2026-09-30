//! Resolve through the owning Owner; a cache invalidation makes this reference stale.
const DatabaseRef = @import("DatabaseRef.zig");

pub const Id = enum(u32) { _ };
database: DatabaseRef,
generation: u64,
id: Id,
