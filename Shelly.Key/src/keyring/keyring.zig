const std = @import("std");
const Io = std.Io;

const gpg = @import("../gpg.zig");
const gpgconf = @import("gpgconf.zig");
const keydir = @import("keydir.zig");
const keyfiles = @import("keyfiles.zig");

pub fn init(io: Io, keyring_path: []const u8) !void {
    const base: std.Io.Dir = .cwd();

    try keydir.createKeyringDir(base, io, keyring_path);

    try keyfiles.ensureKeyringFilesCreated(base, io, keyring_path);
    
    const runner: gpg.Gpg = .{ .io = io, .homedir = keyring_path };

    if (try keyfiles.trustdbNeedsInit(base, io, keyring_path)) {
        try runner.updateTrustdb();
    }

    try keyfiles.applyKeyringPermissions(base, io, keyring_path);

    try gpgconf.ensureGpgConf(base, io, keyring_path);
    try gpgconf.ensureGpgAgentConf(base, io, keyring_path);

    const has_secret_key = try runner.secretKeysAvailable();
    if (!has_secret_key) {
        // TODO(step 9): generate the Pacman Keyring Master Key via
        //   runner.genKey(master_key_batch_input) and set an `updatedb_required = true` flag.
        // TODO(step 10): when a key was generated, run
        //   runner.checkTrustdb() after printing "Updating trust database...".
    }
}
