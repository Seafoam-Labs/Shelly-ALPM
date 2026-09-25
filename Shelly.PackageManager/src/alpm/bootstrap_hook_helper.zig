//! Static executable shipped inside the disposable hook-test package.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.MissingAction;
    if (std.mem.eql(u8, args[1], "fail")) std.process.exit(23);
    if (std.mem.eql(u8, args[1], "second")) {
        const first = try std.Io.Dir.cwd().readFileAlloc(init.io, "/first", init.arena.allocator(), .limited(64));
        if (!std.mem.eql(u8, first, "guest hook ran\n")) return error.HookOrder;
    }
    // Relative paths verify libalpm runs the command with cwd = guest /.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = "guest hook ran\n" });
}
