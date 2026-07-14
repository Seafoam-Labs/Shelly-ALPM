const std = @import("std");
const Io = std.Io;

const gpg = @import("../gpg.zig");
const gpgconf = @import("gpgconf.zig");
const keydir = @import("keydir.zig");
const keyfiles = @import("keyfiles.zig");

/// Batch parameters for `gpg --gen-key --batch` to create local signing key.
const master_key_batch =
    \\%echo Generating pacman keyring master key...
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

    try keydir.createKeyringDir(base, io, keyring_path);
    try keyfiles.ensureKeyringFilesCreated(base, io, keyring_path);

    const gpg_cli: gpg.Gpg = .{ .io = io, .homedir = keyring_path };

    if (try keyfiles.trustdbNeedsInit(base, io, keyring_path)) {
        try gpg_cli.updateTrustdb();
    }

    try keyfiles.applyKeyringPermissions(base, io, keyring_path);

    try gpgconf.ensureGpgConf(base, io, keyring_path);
    try gpgconf.ensureGpgAgentConf(base, io, keyring_path);

    if (!try gpg_cli.secretKeysAvailable()) {
        try out.print("Generating pacman master key. This may take some time.\n", .{});
        try out.flush();
        try gpg_cli.genKey(master_key_batch);

        try out.print("Updating trust database...\n", .{});
        try out.flush();
        try gpg_cli.checkTrustdb();
    }
}
