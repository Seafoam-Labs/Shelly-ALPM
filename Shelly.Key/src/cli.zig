const std = @import("std");

const keyring = @import("keyring/keyring.zig");

pub const exe_name = "shelly-key";

pub const Command = union(enum) {
    help,
    init,
};

pub const Options = struct {
    command: Command = .help,
    init_path: []const u8 = keyring.default_path,
};

pub const ParseError = error{
    UnknownArgument,
};

pub fn parse(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};

    if (args.len <= 1) return opts;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.command = .help;
        } else if (std.mem.eql(u8, arg, "--init")) {
            opts.command = .init;

            if (i + 1 < args.len) {
                i += 1;
                opts.init_path = args[i];
            }
        } else {
            return error.UnknownArgument;
        }
    }

    return opts;
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: {s} [OPTIONS]
        \\
        \\Options:
        \\  --init [path] Initialize gpg keys and ensure correct permissions (default: {s})
        \\  -h, --help    Show this help message
        \\
    , .{ exe_name, keyring.default_path });
}

test "parse uses defaults when only the program name is provided" {
    const args: []const []const u8 = &.{exe_name};
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(keyring.default_path, opts.init_path);
}

test "parse uses defaults for an empty argument slice" {
    const args: []const []const u8 = &.{};
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(keyring.default_path, opts.init_path);
}

test "parse recognizes --help" {
    const args: []const []const u8 = &.{ exe_name, "--help" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(keyring.default_path, opts.init_path);
}

test "parse recognizes -h" {
    const args: []const []const u8 = &.{ exe_name, "-h" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqualStrings(keyring.default_path, opts.init_path);
}

test "parse recognizes --init without a path" {
    const args: []const []const u8 = &.{ exe_name, "--init" };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.init, opts.command);
    try std.testing.expectEqualStrings(keyring.default_path, opts.init_path);
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

test "parse accepts an init path that looks like a flag" {
    const args: []const []const u8 = &.{
        exe_name,
        "--init",
        "--looks-like-a-flag",
    };
    const opts = try parse(args);

    try std.testing.expectEqual(Command.init, opts.command);
    try std.testing.expectEqualStrings("--looks-like-a-flag", opts.init_path);
}

test "printHelp prints the expected usage text" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try printHelp(&aw.writer);

    try std.testing.expectEqualStrings(
        \\Usage: shelly-key [OPTIONS]
        \\
        \\Options:
        \\  --init [path] Initialize gpg keys and ensure correct permissions (default: /etc/pacman.d/gnupg)
        \\  -h, --help    Show this help message
        \\
    ,
        aw.written(),
    );
}
