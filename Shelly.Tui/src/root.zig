//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const model = @import("model.zig");
/// Exported so consumers share the same runtime globals (io, environ_map)
/// that ShellyCli depends on. Do not import runtime.zig directly from
/// another module — that would create a second copy of the globals.
pub const runtime = @import("runtime.zig");
