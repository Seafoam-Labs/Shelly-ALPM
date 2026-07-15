const std = @import("std");
const Io = std.Io;

const Shelly_Key = @import("Shelly_Key");

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const opts = try Shelly_Key.cli.parse(init.arena.allocator(), args);

    switch (opts.command) {
        .help => try Shelly_Key.cli.printHelp(stdout),
        .init => {
            try Shelly_Key.elevate.ensureRoot(
                init.io,
                init.arena.allocator(),
                args,
                init.environ_map.get("PATH").?,
            );

            const init_path = opts.init_path;
            try Shelly_Key.keyring.init(init.io, init_path, stdout);
        },
        .populate => {
            try Shelly_Key.elevate.ensureRoot(
                init.io,
                init.arena.allocator(),
                args,
                init.environ_map.get("PATH").?,
            );

            Shelly_Key.keyring.populate(
                init.io,
                init.arena.allocator(),
                opts.gpgdir,
                opts.populate_from,
                opts.populate_keyrings,
                stdout,
            ) catch |err| switch (err) {
                error.TrustdbMissing => {
                    stderrPrint(init.io, "error: The pacman keyring is not initialized (trustdb.gpg not found).", .{});
                    stderrPrint(init.io, "Run 'shelly-key --init' to initialize the keyring.", .{});
                    std.process.exit(1);
                },
                error.NoSecretKey => {
                    stderrPrint(init.io, "error: There is no secret key available to sign with.", .{});
                    stderrPrint(init.io, "Use 'shelly-key --init' to generate a default secret key.", .{});
                    std.process.exit(1);
                },
                error.NoKeyringsFound => {
                    stderrPrint(init.io, "error: No keyring files exist in {s}.", .{opts.populate_from});
                    std.process.exit(1);
                },
                error.MissingKeyringFile => {
                    const base: std.Io.Dir = .cwd();
                    for (opts.populate_keyrings) |id| {
                        const exists = Shelly_Key.keyfiles.keyringFileExists(
                            base,
                            init.io,
                            opts.populate_from,
                            id,
                        ) catch false;
                        if (!exists) {
                            stderrPrint(
                                init.io,
                                "error: The keyring file {s}/{s}.gpg does not exist.",
                                .{ opts.populate_from, id },
                            );
                        }
                    }
                    std.process.exit(1);
                },
                error.NotImplemented => {
                    stderrPrint(init.io, "error: --populate pipeline is not yet implemented past validation", .{});
                    std.process.exit(1);
                },
                else => return err,
            };
        },
    }
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    Io.File.stderr().writeStreamingAll(io, msg) catch return;
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.UnknownArgument => {
            stderrPrint(init.io, "error: unknown or invalid argument(s). See --help for usage.", .{});
            std.process.exit(1);
        },
        error.MultipleOperations => {
            stderrPrint(init.io, "error: multiple operations specified; run each operation separately.", .{});
            std.process.exit(1);
        },
        error.MissingArgumentValue => {
            stderrPrint(init.io, "error: option requires an argument. See --help for usage.", .{});
            std.process.exit(1);
        },
        error.NoElevator => {
            stderrPrint(init.io, "error: no privilege elevator found (install sudo, doas, or pkexec)", .{});
            std.process.exit(1);
        },
        error.ExecFailed => {
            stderrPrint(init.io, "error: failed to re-exec with elevated privileges", .{});
            std.process.exit(1);
        },
        // Unexpected errors (e.g. OutOfMemory) get the default stack trace.
        else => return err,
    };
    std.process.exit(0);
}
