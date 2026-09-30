//! Storage-specific behavior. Database owns cache generations and indexes.
pub const Local = @import("LocalBackend.zig");
pub const Sync = @import("SyncBackend.zig");

pub const Mode = enum { create, read_only };

pub const Backend = union(enum) { local: Local, sync: Sync };
