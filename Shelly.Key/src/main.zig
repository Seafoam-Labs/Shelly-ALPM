const std = @import("std");
const Io = std.Io;

const Shelly_Key = @import("Shelly_Key");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const opts = Shelly_Key.cli.parse(args) catch |err| {
        switch (err) {
            error.UnknownArgument => try stdout.print("error: unknown or invalid argument(s). See --help for usage.\n", .{}),
        }
        try stdout.flush();
        return err;
    };

    switch (opts.command) {
        .help => {
            try Shelly_Key.cli.printHelp(stdout);
        },
        .init => {
            const init_path = opts.init_path;
            try Shelly_Key.keyring.init(arena, io, init_path);
            try stdout.print("Keyring initialized at {s}\n", .{init_path});
        },
    }

    try stdout.flush();
}
