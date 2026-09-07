//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const model = @import("model.zig");
/// Exported so consumers share the same runtime globals (io, environ_map)
/// that ShellyCli depends on. Do not import runtime.zig directly from
/// another module — that would create a second copy of the globals.
pub const runtime = @import("runtime.zig");

const Io = std.Io;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    _ = @import("ui_decode.zig");
}
