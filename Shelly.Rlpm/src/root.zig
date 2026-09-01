//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const Version = @import("structs/Version.zig");
pub const ParsedDescription = @import("structs/ParsedDescription.zig");

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
    _ = @import("structs/Version.zig");
    _ = @import("structs/PackageRelation.zig");
    _ = @import("structs/Package.zig");
    _ = @import("structs/ParsedDescription.zig");
    _ = @import("structs/Group.zig");
    _ = @import("structs/DatabaseStatus.zig");
    _ = @import("structs/DatabaseUsage.zig");
    _ = @import("structs/SignaturePolicy.zig");
    _ = @import("structs/Database.zig");
}
