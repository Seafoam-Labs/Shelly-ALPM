const std = @import("std");

const keyring = @import("keyring/keyring.zig");

pub const exe_name = "shelly-key";

pub const default_gpgdir = keyring.default_gpgdir;
pub const default_populate_from = keyring.default_populate_from;

pub const Command = union(enum) {
    help,
    init,
    populate,
    updatedb,
    list_keys,
    finger,
    list_sigs,
    export_keys,
    lsign_key,
};

pub const Options = struct {
    command: Command = .help,
    init_path: []const u8 = default_gpgdir,
    gpgdir: []const u8 = default_gpgdir,
    populate_from: []const u8 = default_populate_from,
    populate_keyrings: []const []const u8 = &.{},
    key_ids: []const []const u8 = &.{},
};

pub const ParseError = error{
    UnknownArgument,
    MultipleOperations,
    MissingArgumentValue,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.command = .help;
            return opts;
        } else if (std.mem.eql(u8, arg, "--init")) {
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .init;
        } else if (std.mem.eql(u8, arg, "--updatedb") or std.mem.eql(u8, arg, "-u")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .updatedb;
        } else if (std.mem.eql(u8, arg, "--populate")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .populate;
        } else if (std.mem.eql(u8, arg, "--list-keys") or std.mem.eql(u8, arg, "-l")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .list_keys;
        } else if (std.mem.eql(u8, arg, "--finger") or std.mem.eql(u8, arg, "-f")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .finger;
        } else if (std.mem.eql(u8, arg, "--list-sigs")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .list_sigs;
        } else if (std.mem.eql(u8, arg, "--export") or std.mem.eql(u8, arg, "-e")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .lsign_key) return error.MultipleOperations;
            opts.command = .export_keys;
        } else if (std.mem.eql(u8, arg, "--lsign-key")) {
            if (opts.command == .init) return error.MultipleOperations;
            if (opts.command == .updatedb) return error.MultipleOperations;
            if (opts.command == .populate) return error.MultipleOperations;
            if (opts.command == .list_keys) return error.MultipleOperations;
            if (opts.command == .finger) return error.MultipleOperations;
            if (opts.command == .list_sigs) return error.MultipleOperations;
            if (opts.command == .export_keys) return error.MultipleOperations;
            opts.command = .lsign_key;
        } else if (std.mem.eql(u8, arg, "--gpgdir")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                return error.MissingArgumentValue;
            }
            i += 1;
            opts.gpgdir = args[i];
        } else if (std.mem.eql(u8, arg, "--populate-from")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                return error.MissingArgumentValue;
            }
            i += 1;
            opts.populate_from = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else {
            try positionals.append(allocator, arg);
        }
    }

    switch (opts.command) {
        .help => {
            if (positionals.items.len > 0) return error.UnknownArgument;
        },
        .init => {
            if (positionals.items.len > 1) return error.UnknownArgument;
            if (positionals.items.len == 1) opts.init_path = positionals.items[0];
        },
        .updatedb => {
            if (positionals.items.len > 0) return error.UnknownArgument;
        },
        .list_keys, .finger, .list_sigs, .export_keys, .lsign_key => {
            if (positionals.items.len > 0) {
                opts.key_ids = try positionals.toOwnedSlice(allocator);
            }
        },
        .populate => {
            if (positionals.items.len > 0) {
                opts.populate_keyrings = try positionals.toOwnedSlice(allocator);
            }
        },
    }

    return opts;
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: {s} [OPTIONS] operation [targets]
        \\
        \\Operations:
        \\  --init [dir]              Initialize the package-signing keyring (default: {s})
        \\  --populate [keyring...]   Reload keys from the given keyrings, or every
        \\                            keyring found in the source directory
        \\  -u, --updatedb            Update the trust database
        \\  -l, --list-keys [ids...]  List keys from the keyring
        \\  -f, --finger [ids...]     List keys with their fingerprints
        \\  --list-sigs [ids...]      List keys and their signatures
        \\  -e, --export [ids...]     Export public or secret keys
        \\  --lsign-key <ids...>      Locally sign keys with your master key
        \\
        \\Options:
        \\  --gpgdir <dir>            Set the GnuPG directory (default: {s})
        \\  --populate-from <dir>     Set the source directory for --populate
        \\                            (default: {s})
        \\  -h, --help                Show this help message
        \\
    , .{ exe_name, default_gpgdir, default_gpgdir, default_populate_from });
}

test "parse uses defaults when only the program name is provided" {
    const args: []const []const u8 = &.{exe_name};
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse uses defaults for an empty argument slice" {
    const args: []const []const u8 = &.{};
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse recognizes --help" {
    const args: []const []const u8 = &.{ exe_name, "--help" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
}

test "parse recognizes -h" {
    const args: []const []const u8 = &.{ exe_name, "-h" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
}

test "parse recognizes --init without a path" {
    const args: []const []const u8 = &.{ exe_name, "--init" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.init, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse recognizes --init with a custom path" {
    const args: []const []const u8 = &.{ exe_name, "--init", "/custom/path" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.init, opts.command);
    try std.testing.expectEqualStrings("/custom/path", opts.init_path);
}

test "parse rejects unknown arguments" {
    const args: []const []const u8 = &.{ exe_name, "--bogus" };

    try std.testing.expectError(error.UnknownArgument, parse(std.testing.allocator, args));
}

test "parse does not treat a flag-looking token as the init directory" {
    const args: []const []const u8 = &.{
        exe_name,
        "--init",
        "--looks-like-a-flag",
    };

    try std.testing.expectError(error.UnknownArgument, parse(std.testing.allocator, args));
}

test "parse rejects --init followed by --populate" {
    const args: []const []const u8 = &.{ exe_name, "--init", "--populate" };

    try std.testing.expectError(error.MultipleOperations, parse(std.testing.allocator, args));
}

test "parse prints help when --init is combined with --help" {
    const args: []const []const u8 = &.{ exe_name, "--init", "--help" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
}

test "parse recognizes --populate without keyring IDs" {
    const args: []const []const u8 = &.{ exe_name, "--populate" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse collects a single keyring ID after --populate" {
    const args: []const []const u8 = &.{ exe_name, "--populate", "archlinux" };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.populate_keyrings);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqual(@as(usize, 1), opts.populate_keyrings.len);
    try std.testing.expectEqualStrings("archlinux", opts.populate_keyrings[0]);
}

test "parse collects multiple keyring IDs after --populate" {
    const args: []const []const u8 = &.{
        exe_name,
        "--populate",
        "archlinux",
        "cachyos",
        "arch32",
    };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.populate_keyrings);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqual(@as(usize, 3), opts.populate_keyrings.len);
    try std.testing.expectEqualStrings("archlinux", opts.populate_keyrings[0]);
    try std.testing.expectEqualStrings("cachyos", opts.populate_keyrings[1]);
    try std.testing.expectEqualStrings("arch32", opts.populate_keyrings[2]);
}

test "parse recognizes --gpgdir" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir", "/custom/gnupg", "--populate" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings("/custom/gnupg", opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
}

test "parse recognizes --populate-from" {
    const args: []const []const u8 = &.{
        exe_name,
        "--populate-from",
        "/custom/keyrings",
        "--populate",
    };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings("/custom/keyrings", opts.populate_from);
}

test "parse combines --gpgdir, --populate-from, and keyring IDs" {
    const args: []const []const u8 = &.{
        exe_name,
        "--gpgdir",
        "/g",
        "--populate-from",
        "/p",
        "--populate",
        "archlinux",
        "cachyos",
    };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.populate_keyrings);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings("/g", opts.gpgdir);
    try std.testing.expectEqualStrings("/p", opts.populate_from);
    try std.testing.expectEqual(@as(usize, 2), opts.populate_keyrings.len);
    try std.testing.expectEqualStrings("archlinux", opts.populate_keyrings[0]);
    try std.testing.expectEqualStrings("cachyos", opts.populate_keyrings[1]);
}

test "parse accepts flags after --populate keyrings" {
    const args: []const []const u8 = &.{
        exe_name,
        "--populate",
        "archlinux",
        "--gpgdir",
        "/g",
        "cachyos",
    };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.populate_keyrings);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings("/g", opts.gpgdir);
    try std.testing.expectEqual(@as(usize, 2), opts.populate_keyrings.len);
    try std.testing.expectEqualStrings("archlinux", opts.populate_keyrings[0]);
    try std.testing.expectEqualStrings("cachyos", opts.populate_keyrings[1]);
}

test "parse rejects --populate combined with --init" {
    const args: []const []const u8 = &.{ exe_name, "--populate", "--init" };

    try std.testing.expectError(error.MultipleOperations, parse(std.testing.allocator, args));
}

test "parse detects the conflict even with options between the operations" {
    const args: []const []const u8 = &.{
        exe_name,
        "--populate",
        "--gpgdir",
        "/x",
        "--init",
    };

    try std.testing.expectError(error.MultipleOperations, parse(std.testing.allocator, args));
}

test "parse treats --populate as idempotent when repeated" {
    const args: []const []const u8 = &.{ exe_name, "--populate", "--populate" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse recognizes --lsign-key with a single key id" {
    const args: []const []const u8 = &.{ exe_name, "--lsign-key", "ABC1234" };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.key_ids);

    try std.testing.expectEqual(Command.lsign_key, opts.command);
    try std.testing.expectEqual(@as(usize, 1), opts.key_ids.len);
    try std.testing.expectEqualStrings("ABC1234", opts.key_ids[0]);
}

test "parse collects multiple key ids after --lsign-key" {
    const args: []const []const u8 = &.{ exe_name, "--lsign-key", "ABC1234", "DEF5678" };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.key_ids);

    try std.testing.expectEqual(Command.lsign_key, opts.command);
    try std.testing.expectEqual(@as(usize, 2), opts.key_ids.len);
    try std.testing.expectEqualStrings("ABC1234", opts.key_ids[0]);
    try std.testing.expectEqualStrings("DEF5678", opts.key_ids[1]);
}

test "parse accepts --gpgdir with --lsign-key" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir", "/tmp/k", "--lsign-key", "ABC1234" };
    const opts = try parse(std.testing.allocator, args);
    defer std.testing.allocator.free(opts.key_ids);

    try std.testing.expectEqual(Command.lsign_key, opts.command);
    try std.testing.expectEqualStrings("/tmp/k", opts.gpgdir);
    try std.testing.expectEqual(@as(usize, 1), opts.key_ids.len);
}

test "parse rejects --lsign-key combined with --init" {
    const args: []const []const u8 = &.{ exe_name, "--lsign-key", "ABC1234", "--init" };

    try std.testing.expectError(error.MultipleOperations, parse(std.testing.allocator, args));
}

test "parse rejects --lsign-key combined with --list-keys" {
    const args: []const []const u8 = &.{ exe_name, "--list-keys", "--lsign-key", "ABC1234" };

    try std.testing.expectError(error.MultipleOperations, parse(std.testing.allocator, args));
}

test "parse rejects --gpgdir without a value" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir" };

    try std.testing.expectError(error.MissingArgumentValue, parse(std.testing.allocator, args));
}

test "parse rejects --populate-from without a value" {
    const args: []const []const u8 = &.{ exe_name, "--populate-from" };

    try std.testing.expectError(error.MissingArgumentValue, parse(std.testing.allocator, args));
}

test "parse rejects a bare positional without --populate" {
    const args: []const []const u8 = &.{ exe_name, "archlinux" };

    try std.testing.expectError(error.UnknownArgument, parse(std.testing.allocator, args));
}

test "parse does not mutate defaults when only --gpgdir is given" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir", "/x" };
    const opts = try parse(std.testing.allocator, args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings("/x", opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
}

test "printHelp prints the expected usage text" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try printHelp(&aw.writer);

    try std.testing.expectEqualStrings(
        \\Usage: shelly-key [OPTIONS] operation [targets]
        \\
        \\Operations:
        \\  --init [dir]              Initialize the package-signing keyring (default: /etc/pacman.d/gnupg)
        \\  --populate [keyring...]   Reload keys from the given keyrings, or every
        \\                            keyring found in the source directory
        \\  -u, --updatedb            Update the trust database
        \\  -l, --list-keys [ids...]  List keys from the keyring
        \\  -f, --finger [ids...]     List keys with their fingerprints
        \\  --list-sigs [ids...]      List keys and their signatures
        \\  -e, --export [ids...]     Export public or secret keys
        \\  --lsign-key <ids...>      Locally sign keys with your master key
        \\
        \\Options:
        \\  --gpgdir <dir>            Set the GnuPG directory (default: /etc/pacman.d/gnupg)
        \\  --populate-from <dir>     Set the source directory for --populate
        \\                            (default: /usr/share/pacman/keyrings)
        \\  -h, --help                Show this help message
        \\
    ,
        aw.written(),
    );
}
