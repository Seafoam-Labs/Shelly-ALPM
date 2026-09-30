//! Noninstalled host for library tests using the production worker dispatcher.
const std = @import("std");
const Workers = @import("workers");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.process.exit(Workers.dispatch(init, args[1..]) orelse 2);
}
