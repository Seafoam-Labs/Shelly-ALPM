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
    env_map: *const std.process.Environ.Map,
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

    var path_buf: [4096]u8 = undefined;
    for (keyring_ids) |id| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.gpg", .{ populate_from, id }) catch return error.PathTooLong;
        try gpg_cli.importKeyring(path);
    }

    var keys_to_sign = try collectKeysToSign(allocator, gpg_cli, base, io, populate_from, keyring_ids);
    defer {
        var it = keys_to_sign.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        keys_to_sign.deinit();
    }

    if (keys_to_sign.count() > 0) {
        try locallySignKeys(allocator, gpg_cli, env_map, stdout, &keys_to_sign);

        try importOwnertrust(
            gpg_cli,
            base,
            io,
            populate_from,
            keyring_ids,
            stdout,
        );
    }

    // Remaining steps (revoked metadata, disabling, and the final trustdb
    // update) are not yet implemented.
    return error.NotImplemented;
}

fn collectKeysToSign(
    allocator: std.mem.Allocator,
    gpg_cli: gpg.Gpg,
    base: std.Io.Dir,
    io: Io,
    populate_from: []const u8,
    keyring_ids: []const []const u8,
) !std.StringHashMap(void) {
    const secret_key_id = try gpg_cli.firstSecretKeyId(allocator) orelse return error.NoSecretKey;
    defer allocator.free(secret_key_id);

    var keys_to_sign = std.StringHashMap(void).init(allocator);
    errdefer {
        var it = keys_to_sign.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        keys_to_sign.deinit();
    }

    for (keyring_ids) |id| {
        const trusted = try keyfiles.readTrustedFingerprints(
            allocator,
            base,
            io,
            populate_from,
            id,
        );
        defer {
            for (trusted) |fp| allocator.free(fp);
            allocator.free(trusted);
        }

        for (trusted) |fp| {
            if (keys_to_sign.contains(fp)) continue;
            if (try gpg_cli.keyIsLsigned(allocator, secret_key_id, fp)) continue;
            const owned = try allocator.dupe(u8, fp);
            try keys_to_sign.put(owned, {});
        }
    }

    return keys_to_sign;
}

fn locallySignKeys(
    allocator: std.mem.Allocator,
    gpg_cli: gpg.Gpg,
    env_map: *const std.process.Environ.Map,
    stdout: *Io.Writer,
    keys_to_sign: *const std.StringHashMap(void),
) !void {
    try stdout.print("Locally signing trusted keys in keyring...\n", .{});
    try stdout.flush();

    var it = keys_to_sign.iterator();
    while (it.next()) |entry| {
        try stdout.print("  Locally signing key {s}...\n", .{entry.key_ptr.*});
        try stdout.flush();
        try gpg_cli.locallySignKey(allocator, env_map, entry.key_ptr.*);
    }

    try stdout.print("  Locally signed {d} key(s).\n", .{keys_to_sign.count()});
    try stdout.flush();
}

fn importOwnertrust(
    gpg_cli: gpg.Gpg,
    base: std.Io.Dir,
    io: Io,
    populate_from: []const u8,
    keyring_ids: []const []const u8,
    stdout: *Io.Writer,
) !void {
    var path_buf: [4096]u8 = undefined;
    var imported_any = false;
    for (keyring_ids) |id| {
        if (!try keyfiles.trustedFileNonempty(base, io, populate_from, id)) continue;
        if (!imported_any) {
            try stdout.print("Importing ownertrust values...\n", .{});
            try stdout.flush();
            imported_any = true;
        }
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}-trusted", .{ populate_from, id }) catch
            return error.PathTooLong;
        try gpg_cli.importOwnertrust(path);
    }
}
