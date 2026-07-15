const std = @import("std");

const keyring = @import("keyring/keyring.zig");

pub const exe_name = "shelly-key";

pub const default_gpgdir = keyring.default_gpgdir;
pub const default_populate_from = keyring.default_populate_from;

pub const Command = union(enum) {
    help,
    init,
    populate,
};

pub const Options = struct {
    command: Command = .help,
    init_path: []const u8 = default_gpgdir,
    gpgdir: []const u8 = default_gpgdir,
    populate_from: []const u8 = default_populate_from,
    populate_keyrings: []const []const u8 = &.{},
};

pub const ParseError = error{
    UnknownArgument,
    MultipleOperations,
    MissingArgumentValue,
};

pub fn parse(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};

    if (args.len <= 1) return opts;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.command = .help;
            return opts;
        } else if (std.mem.eql(u8, arg, "--init")) {
            try setOperation(&opts, .init);
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                opts.init_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--populate")) {
            try setOperation(&opts, .populate);
        } else if (std.mem.eql(u8, arg, "--gpgdir")) {
            opts.gpgdir = try takeValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--populate-from")) {
            opts.populate_from = try takeValue(args, &i);
        } else {
            if (std.mem.startsWith(u8, arg, "-")) {
                return error.UnknownArgument;
            }
            if (opts.command != .populate) {
                return error.UnknownArgument;
            }
            for (args[i..]) |positional| {
                if (std.mem.startsWith(u8, positional, "-")) {
                    return error.UnknownArgument;
                }
            }
            opts.populate_keyrings = args[i..];
            return opts;
        }
    }

    return opts;
}

fn takeValue(args: []const []const u8, i: *usize) ParseError![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingArgumentValue;
    i.* += 1;
    return args[i.*];
}

fn setOperation(opts: *Options, cmd: Command) ParseError!void {
    switch (opts.command) {
        .help => opts.command = cmd,
        else => {
            if (std.meta.activeTag(opts.command) != std.meta.activeTag(cmd)) {
                return error.MultipleOperations;
            }
        },
    }
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: {s} [OPTIONS] operation [targets]
        \\
        \\Operations:
        \\  --init [dir]              Initialize the pacman keyring (default: {s})
        \\  --populate [keyring...]   Reload keys from the given keyrings, or every
        \\                            keyring found in the source directory
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
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse uses defaults for an empty argument slice" {
    const args: []const []const u8 = &.{};
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse recognizes --help" {
    const args: []const []const u8 = &.{ exe_name, "--help" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
}

test "parse recognizes -h" {
    const args: []const []const u8 = &.{ exe_name, "-h" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
}

test "parse recognizes --init without a path" {
    const args: []const []const u8 = &.{ exe_name, "--init" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.init, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse recognizes --init with a custom path" {
    const args: []const []const u8 = &.{ exe_name, "--init", "/custom/path" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.init, opts.command);
    try std.testing.expectEqualStrings("/custom/path", opts.init_path);
}

test "parse rejects unknown arguments" {
    const args: []const []const u8 = &.{ exe_name, "--bogus" };

    try std.testing.expectError(error.UnknownArgument, parse(args));
}

test "parse does not treat a flag-looking token as the init directory" {
    const args: []const []const u8 = &.{
        exe_name,
        "--init",
        "--looks-like-a-flag",
    };

    try std.testing.expectError(error.UnknownArgument, parse(args));
}

test "parse rejects --init followed by --populate" {
    const args: []const []const u8 = &.{ exe_name, "--init", "--populate" };

    try std.testing.expectError(error.MultipleOperations, parse(args));
}

test "parse prints help when --init is combined with --help" {
    const args: []const []const u8 = &.{ exe_name, "--init", "--help" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.init_path);
}

test "parse recognizes --populate without keyring IDs" {
    const args: []const []const u8 = &.{ exe_name, "--populate" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings(default_gpgdir, opts.gpgdir);
    try std.testing.expectEqualStrings(default_populate_from, opts.populate_from);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse collects a single keyring ID after --populate" {
    const args: []const []const u8 = &.{ exe_name, "--populate", "archlinux" };
    const opts = try parse(args);

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
    const opts = try parse(args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqual(@as(usize, 3), opts.populate_keyrings.len);
    try std.testing.expectEqualStrings("archlinux", opts.populate_keyrings[0]);
    try std.testing.expectEqualStrings("cachyos", opts.populate_keyrings[1]);
    try std.testing.expectEqualStrings("arch32", opts.populate_keyrings[2]);
}

test "parse recognizes --gpgdir" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir", "/custom/gnupg", "--populate" };
    const opts = try parse(args);

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
    const opts = try parse(args);

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
    const opts = try parse(args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqualStrings("/g", opts.gpgdir);
    try std.testing.expectEqualStrings("/p", opts.populate_from);
    try std.testing.expectEqual(@as(usize, 2), opts.populate_keyrings.len);
    try std.testing.expectEqualStrings("archlinux", opts.populate_keyrings[0]);
    try std.testing.expectEqualStrings("cachyos", opts.populate_keyrings[1]);
}

test "parse rejects --populate combined with --init" {
    const args: []const []const u8 = &.{ exe_name, "--populate", "--init" };

    try std.testing.expectError(error.MultipleOperations, parse(args));
}

test "parse detects the conflict even with options between the operations" {
    const args: []const []const u8 = &.{
        exe_name,
        "--populate",
        "--gpgdir",
        "/x",
        "--init",
    };

    try std.testing.expectError(error.MultipleOperations, parse(args));
}

test "parse treats --populate as idempotent when repeated" {
    const args: []const []const u8 = &.{ exe_name, "--populate", "--populate" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.populate, opts.command);
    try std.testing.expectEqual(@as(usize, 0), opts.populate_keyrings.len);
}

test "parse rejects --gpgdir without a value" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir" };

    try std.testing.expectError(error.MissingArgumentValue, parse(args));
}

test "parse rejects --populate-from without a value" {
    const args: []const []const u8 = &.{ exe_name, "--populate-from" };

    try std.testing.expectError(error.MissingArgumentValue, parse(args));
}

test "parse rejects a bare positional without --populate" {
    const args: []const []const u8 = &.{ exe_name, "archlinux" };

    try std.testing.expectError(error.UnknownArgument, parse(args));
}

test "parse does not mutate defaults when only --gpgdir is given" {
    const args: []const []const u8 = &.{ exe_name, "--gpgdir", "/x" };
    const opts = try parse(args);

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
        \\  --init [dir]              Initialize the pacman keyring (default: /etc/pacman.d/gnupg)
        \\  --populate [keyring...]   Reload keys from the given keyrings, or every
        \\                            keyring found in the source directory
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
