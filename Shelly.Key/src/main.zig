const std = @import("std");
const Io = std.Io;

const Shelly_Key = @import("Shelly_Key");

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const opts = try Shelly_Key.cli.parse(args);

    switch (opts.command) {
        .help => try Shelly_Key.cli.printHelp(stdout),
        .init => {
            try Shelly_Key.elevate.ensureRoot(
                init.io,
                init.arena,
                args,
                init.environ_map.get("PATH").?,
            );

            const init_path = opts.init_path;
            try Shelly_Key.keyring.init(init.io, init_path, stdout);
        },
        .populate => {
            try Shelly_Key.elevate.ensureRoot(
                init.io,
                init.arena,
                args,
                init.environ_map.get("PATH").?,
            );

            // TODO: implement the --populate pipeline
            try Io.File.stderr().writeStreamingAll(init.io, "error: --populate is not yet implemented\n");
            std.process.exit(1);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.UnknownArgument => {
            try Io.File.stderr().writeStreamingAll(init.io, "error: unknown or invalid argument(s). See --help for usage.\n");
            std.process.exit(1);
        },
        error.MultipleOperations => {
            try Io.File.stderr().writeStreamingAll(init.io, "error: multiple operations specified; run each operation separately.\n");
            std.process.exit(1);
        },
        error.MissingArgumentValue => {
            try Io.File.stderr().writeStreamingAll(init.io, "error: option requires an argument. See --help for usage.\n");
            std.process.exit(1);
        },
        error.NoElevator => {
            try Io.File.stderr().writeStreamingAll(init.io, "error: no privilege elevator found (install sudo, doas, or pkexec)\n");
            std.process.exit(1);
        },
        error.ExecFailed => {
            try Io.File.stderr().writeStreamingAll(init.io, "error: failed to re-exec with elevated privileges\n");
            std.process.exit(1);
        },
        // Unexpected errors (e.g. OutOfMemory) get the default stack trace.
        else => return err,
    };
    std.process.exit(0);
}
