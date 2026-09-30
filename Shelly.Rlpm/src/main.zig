//! Read-only example. Paths must be supplied explicitly; no host paths default.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (rlpm.Workers.dispatch(init, args[1..])) |code| std.process.exit(code);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--help"))) {
        try writer.writeAll(
            "Usage: Shelly_Rlpm ROOT DBPATH\nRead local package names and versions without modifying the database.\n",
        );
    } else if (args.len != 3) {
        return error.InvalidArguments;
    } else {
        var owner = try rlpm.Owner.init(
            init.io,
            init.gpa,
            .{
                .root = args[1],
                .database_path = args[2],
                .local_database_mode = .read_only,
            },
            &.{},
        );
        defer owner.deinit() catch unreachable;
        const local = owner.localDatabase().?;
        for (try owner.packageIds(local)) |id| {
            const package = try owner.package(try owner.packageReference(local, id));
            try writer.print("{s} {s}\n", .{ package.name, package.version.raw });
        }
    }
    try writer.flush();
}
