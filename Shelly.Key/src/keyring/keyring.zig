const std = @import("std");
const Io = std.Io;

const gpg = @import("../gpg.zig");
const gpgconf = @import("gpgconf.zig");
const keydir = @import("keydir.zig");
const keyfiles = @import("keyfiles.zig");

/// Default keyring location, used when `--init` is invoked without a path.
pub const default_gpgdir = "/etc/pacman.d/gnupg";

/// Default source directory for `--populate`, used when `--populate-from` is not given.
pub const default_populate_from = "/usr/share/pacman/keyrings";

/// Batch parameters for `gpg --gen-key --batch` to create local signing key.
const master_key_batch =
    \\%echo Generating keyring master key...
    \\Key-Type: RSA
    \\Key-Length: 4096
    \\Key-Usage: sign
    \\Name-Real: Pacman Keyring Master Key
    \\Name-Email: pacman@localhost
    \\Expire-Date: 0
    \\%no-protection
    \\%commit
    \\%echo Done
    \\
;

pub fn init(io: Io, keyring_path: []const u8, out: *Io.Writer) !void {
    const base: std.Io.Dir = .cwd();

    try keydir.ensureKeyringDir(base, io, keyring_path);

    const gpg_cli: gpg.Gpg = .{ .io = io, .homedir = keyring_path };

    if (!try keyfiles.trustdbExists(base, io, keyring_path)) {
        try gpg_cli.updateTrustdb();
    }

    try keyfiles.applyKeyringPermissions(base, io, keyring_path);

    try gpgconf.ensureGpgConf(base, io, keyring_path);
    try gpgconf.ensureGpgAgentConf(base, io, keyring_path);

    if (try gpg_cli.secretKeysAvailable()) {
        try out.print("Master key already exists. Skipping generation.\n", .{});
    } else {
        try out.print("Generating master key. This may take some time.\n", .{});
        try out.flush();
        try gpg_cli.genKey(master_key_batch);

        try out.print("Updating trust database...\n", .{});
        try out.flush();
        try gpg_cli.checkTrustdb();

        try out.print("Keyring initialized at {s}\n", .{keyring_path});
    }
}

pub fn populate(
    io: Io,
    allocator: std.mem.Allocator,
    gpgdir: []const u8,
    populate_from: []const u8,
    requested: []const []const u8,
    stdout: *Io.Writer,
) !void {
    const base: std.Io.Dir = .cwd();

    if (!try keyfiles.trustdbExists(base, io, gpgdir)) return error.TrustdbMissing;

    const gpg_cli: gpg.Gpg = .{ .io = io, .homedir = gpgdir };

    if (!try gpg_cli.secretKeysAvailable()) return error.NoSecretKey;

    const keyring_ids = try keyfiles.resolveKeyrings(allocator, base, io, populate_from, requested);
    defer {
        for (keyring_ids) |id| allocator.free(id);
        allocator.free(keyring_ids);
    }

    // TODO: implement (import, sign, disable, trustdb update).
    try stdout.print("Resolved {d} keyring(s):", .{keyring_ids.len});
    for (keyring_ids) |id| try stdout.print(" {s}", .{id});
    try stdout.print("\n", .{});
    try stdout.flush();

    return error.NotImplemented;
}
