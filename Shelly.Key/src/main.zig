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
        .init => try Shelly_Key.keyring.init(
            init.io,
            init.arena.allocator(),
            args,
            init.environ_map.get("PATH").?,
            opts.init_path,
            stdout,
        ),
        .updatedb => Shelly_Key.keyring.updatedb(
            init.io,
            init.arena.allocator(),
            args,
            init.environ_map.get("PATH").?,
            opts.gpgdir,
            stdout,
        ) catch |err| switch (err) {
            error.GpgFailed => {
                stderrPrint(init.io, "Could not update the trust database.", .{});
                std.process.exit(1);
            },
            else => return err,
        },
        .list_keys => Shelly_Key.keyring.listKeys(
            init.io,
            opts.gpgdir,
            opts.key_ids,
        ) catch |err| switch (err) {
            error.GpgFailed => {
                stderrPrint(init.io, "Could not complete keyring operation {s} in {f}. GPG reported a failure. Review the GPG output for the selected keys.\n\nTechnical details: GpgFailed", .{ @tagName(opts.command), @import("diagnostics").safe(opts.gpgdir) });
                std.process.exit(1);
            },
            else => return err,
        },
        .finger => Shelly_Key.keyring.finger(
            init.io,
            opts.gpgdir,
            opts.key_ids,
        ) catch |err| switch (err) {
            error.GpgFailed => {
                stderrPrint(init.io, "Could not complete keyring operation {s} in {f}. GPG reported a failure. Review the GPG output for the selected keys.\n\nTechnical details: GpgFailed", .{ @tagName(opts.command), @import("diagnostics").safe(opts.gpgdir) });
                std.process.exit(1);
            },
            else => return err,
        },
        .list_sigs => Shelly_Key.keyring.listSigs(
            init.io,
            opts.gpgdir,
            opts.key_ids,
        ) catch |err| switch (err) {
            error.GpgFailed => {
                stderrPrint(init.io, "Could not complete keyring operation {s} in {f}. GPG reported a failure. Review the GPG output for the selected keys.\n\nTechnical details: GpgFailed", .{ @tagName(opts.command), @import("diagnostics").safe(opts.gpgdir) });
                std.process.exit(1);
            },
            else => return err,
        },
        .export_keys => Shelly_Key.keyring.exportKeys(
            init.io,
            init.arena.allocator(),
            opts.gpgdir,
            opts.key_ids,
        ) catch |err| switch (err) {
            error.GpgFailed => {
                stderrPrint(init.io, "Could not complete keyring operation {s} in {f}. GPG reported a failure. Review the GPG output for the selected keys.\n\nTechnical details: GpgFailed", .{ @tagName(opts.command), @import("diagnostics").safe(opts.gpgdir) });
                std.process.exit(1);
            },
            else => return err,
        },
        .lsign_key => Shelly_Key.keyring.lsignKey(
            init.io,
            init.arena.allocator(),
            args,
            init.environ_map.get("PATH").?,
            opts.gpgdir,
            opts.key_ids,
            stdout,
        ) catch |err| switch (err) {
            error.NoTargetsSpecified => {
                stderrPrint(init.io, "Specify at least one key ID for this operation. See shelly-key --help for usage.", .{});
                std.process.exit(1);
            },
            error.NoSecretKey => {
                stderrPrint(init.io, "Could not sign keys because keyring {f} has no secret signing key.", .{@import("diagnostics").safe(opts.gpgdir)});
                stderrPrint(init.io, "Initialize the intended keyring before signing keys: shelly-key --init {f}{s}", .{ @import("diagnostics").shellQuote(opts.gpgdir), if (opts.user) " --user" else "" });
                std.process.exit(1);
            },
            error.GpgFailed => {
                stderrPrint(init.io, "Could not complete keyring operation {s} in {f}. GPG reported a failure. Review the GPG output for the selected keys.\n\nTechnical details: GpgFailed", .{ @tagName(opts.command), @import("diagnostics").safe(opts.gpgdir) });
                std.process.exit(1);
            },
            else => return err,
        },
        .recv_keys => Shelly_Key.keyring.recvKeys(
            init.io,
            init.arena.allocator(),
            args,
            init.environ_map.get("PATH").?,
            opts.gpgdir,
            opts.key_ids,
            opts.keyserver,
            opts.user,
            stdout,
        ) catch |err| switch (err) {
            error.NoTargetsSpecified => {
                stderrPrint(init.io, "Specify at least one key ID for this operation. See shelly-key --help for usage.", .{});
                std.process.exit(1);
            },
            error.GpgFailed => {
                stderrPrint(init.io, "Could not receive the selected keys from the configured keyserver. Check the key ID and keyserver before retrying.", .{});
                std.process.exit(1);
            },
            else => return err,
        },
        .refresh_keys => Shelly_Key.keyring.refreshKeys(
            init.io,
            init.arena.allocator(),
            args,
            init.environ_map.get("PATH").?,
            opts.gpgdir,
            opts.key_ids,
            opts.keyserver,
            opts.user,
            stdout,
        ) catch |err| switch (err) {
            error.KeyNotFoundLocally => {
                stderrPrint(init.io, "Could not refresh the selected keys because they are not in keyring {f}. Check the key IDs or receive the keys first.", .{@import("diagnostics").safe(opts.gpgdir)});
                std.process.exit(1);
            },
            error.GpgFailed => {
                stderrPrint(init.io, "Could not refresh the selected keys from the configured keyserver.", .{});
                std.process.exit(1);
            },
            else => return err,
        },
        .populate => Shelly_Key.keyring.populate(
            init.io,
            init.arena.allocator(),
            args,
            init.environ_map,
            opts.gpgdir,
            opts.populate_from,
            opts.populate_keyrings,
            stdout,
        ) catch |err| switch (err) {
            error.TrustdbMissing => {
                stderrPrint(
                    init.io,
                    "The package-signing keyring at {0f} is not initialized. Initialize this keyring before populating it.",
                    .{@import("diagnostics").safe(opts.gpgdir)},
                );
                stderrPrint(
                    init.io,
                    "Initialize the keyring at {0f} first.",
                    .{@import("diagnostics").safe(opts.gpgdir)},
                );
                std.process.exit(1);
            },
            error.NoSecretKey => {
                stderrPrint(init.io, "Could not sign keys because keyring {f} has no secret signing key.", .{@import("diagnostics").safe(opts.gpgdir)});
                stderrPrint(init.io, "Initialize the intended keyring before signing keys: shelly-key --init {f}{s}", .{ @import("diagnostics").shellQuote(opts.gpgdir), if (opts.user) " --user" else "" });
                std.process.exit(1);
            },
            error.NoKeyringsFound => {
                stderrPrint(init.io, "No keyring files were found in {0f}. Check --populate-from or install the package that supplies the requested keyring files.", .{@import("diagnostics").safe(opts.populate_from)});
                std.process.exit(1);
            },
            error.PopulateFromMissing => {
                stderrPrint(
                    init.io,
                    "The keyring source directory {0f} does not exist. Check --populate-from or install the package that supplies the keyring files.",
                    .{@import("diagnostics").safe(opts.populate_from)},
                );
                stderrPrint(
                    init.io,
                    "Check --populate-from or install a package that ships keyring files.",
                    .{},
                );
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
                            "Keyring file {0f}/{1f}.gpg does not exist. Check the requested keyring name and source directory.",
                            .{ @import("diagnostics").safe(opts.populate_from), @import("diagnostics").safe(id) },
                        );
                    }
                }
                std.process.exit(1);
            },
            else => return err,
        },
    }
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "Could not display the complete keyring error because its details exceed the output buffer.\n";
    Io.File.stderr().writeStreamingAll(io, msg) catch return;
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.UnknownArgument => {
            stderrPrint(init.io, "An unrecognized or invalid argument was supplied. See shelly-key --help for usage.", .{});
            std.process.exit(1);
        },
        error.MultipleOperations => {
            stderrPrint(init.io, "Multiple keyring operations were specified. Run each operation separately.", .{});
            std.process.exit(1);
        },
        error.MissingArgumentValue => {
            stderrPrint(init.io, "An option requires a value. See shelly-key --help for usage.", .{});
            std.process.exit(1);
        },
        error.NoElevator => {
            stderrPrint(init.io, "Could not request administrator privileges because no authorization helper is installed. Install or configure sudo, doas, or pkexec.", .{});
            std.process.exit(1);
        },
        error.ExecFailed => {
            stderrPrint(init.io, "Could not restart shelly-key with administrator privileges.", .{});
            std.process.exit(1);
        },
        else => {
            stderrPrint(init.io, "Could not complete the keyring operation. {s}\n\nTechnical details: {s}", .{
                @import("diagnostics").cause(err), @errorName(err),
            });
            std.process.exit(1);
        },
    };
    std.process.exit(0);
}
