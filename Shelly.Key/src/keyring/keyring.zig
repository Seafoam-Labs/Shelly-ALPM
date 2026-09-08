const std = @import("std");
const Io = std.Io;

const elevate = @import("../helpers/elevate.zig");
const gpg = @import("../gpg.zig");
const gpgconf = @import("gpgconf.zig");
const keydir = @import("keydir.zig");
const keyfiles = @import("keyfiles.zig");

/// Default keyring location, used when `--init` is invoked without a path.
pub const default_gpgdir = "/etc/pacman.d/gnupg";

/// Default source directory for `--populate`, used when `--populate-from` is not given.
pub const default_populate_from = "/usr/share/pacman/keyrings";

/// UID of the locally generated master key, excluded from `--refresh-keys`
/// because it does not exist on remote servers.
pub const master_key_uid = "shelly@localhost";

/// Master key UID found on keyrings initialized by pacman-key (or earlier
/// shelly-key releases); excluded from refreshes as well, since shelly shares
/// `/etc/pacman.d/gnupg` with pacman.
pub const legacy_master_key_uid = "pacman@localhost";

/// Batch parameters for `gpg --gen-key --batch` to create local signing key.
const master_key_batch =
    \\%echo Generating keyring master key...
    \\Key-Type: RSA
    \\Key-Length: 4096
    \\Key-Usage: sign
    \\Name-Real: Shelly Keyring Master Key
    \\Name-Email: shelly@localhost
    \\Expire-Date: 0
    \\%no-protection
    \\%commit
    \\%echo Done
    \\
;

pub fn init(
    io: Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
    keyring_path: []const u8,
    out: *Io.Writer,
) !void {
    try elevate.ensureRoot(io, allocator, args, path_env);

    const base: std.Io.Dir = .cwd();

    try keydir.ensureKeyringDir(base, io, keyring_path);
    // GnuPG selects its public-key storage format on first use. Match
    // pacman-key by creating pubring.gpg before invoking GnuPG so libalpm can
    // read the resulting keyring directly.
    try keyfiles.ensureAlpmKeyringFiles(base, io, keyring_path);

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

pub fn updatedb(
    io: Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
    gpgdir: []const u8,
    stdout: *Io.Writer,
) !void {
    try elevate.ensureRoot(io, allocator, args, path_env);

    try stdout.print("Updating trust database...\n", .{});
    try stdout.flush();
    const gpg_cli = gpg.Gpg{ .io = io, .homedir = gpgdir };
    try gpg_cli.checkTrustdb();
}

pub fn listKeys(
    io: Io,
    gpgdir: []const u8,
    key_ids: []const []const u8,
) !void {
    const gpg_cli = gpg.Gpg{ .io = io, .homedir = gpgdir };
    try gpg_cli.listKeys(key_ids);
}

pub fn finger(
    io: Io,
    gpgdir: []const u8,
    key_ids: []const []const u8,
) !void {
    const gpg_cli = gpg.Gpg{ .io = io, .homedir = gpgdir };
    try gpg_cli.finger(key_ids);
}

pub fn listSigs(
    io: Io,
    gpgdir: []const u8,
    key_ids: []const []const u8,
) !void {
    const gpg_cli = gpg.Gpg{ .io = io, .homedir = gpgdir };
    try gpg_cli.listSigs(key_ids);
}

pub fn exportKeys(
    io: Io,
    allocator: std.mem.Allocator,
    gpgdir: []const u8,
    key_ids: []const []const u8,
) !void {
    const gpg_cli = gpg.Gpg{ .io = io, .homedir = gpgdir };
    for (key_ids) |key_id| {
        try ensureKeyExists(allocator, gpg_cli, key_id);
    }
    try gpg_cli.exportKeys(key_ids);
}

pub fn lsignKey(
    io: Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
    gpgdir: []const u8,
    key_ids: []const []const u8,
    stdout: *Io.Writer,
) !void {
    try elevate.ensureRoot(io, allocator, args, path_env);

    if (key_ids.len == 0) return error.NoTargetsSpecified;

    const gpg_cli = gpg.Gpg{ .io = io, .homedir = gpgdir };

    if (!try gpg_cli.secretKeysAvailable()) return error.NoSecretKey;

    for (key_ids) |key_id| {
        try ensureKeyExists(allocator, gpg_cli, key_id);
    }

    var signed_count: usize = 0;
    var had_failure = false;
    for (key_ids) |key_id| {
        try stdout.print("Locally signing key {s}...\n", .{key_id});
        try stdout.flush();
        gpg_cli.locallySignKey(key_id) catch {
            try stdout.print("{s} could not be locally signed.\n", .{key_id});
            try stdout.flush();
            had_failure = true;
            continue;
        };
        signed_count += 1;
    }

    if (had_failure) return error.GpgFailed;

    if (signed_count > 0) {
        try stdout.print("Locally signed {d} key(s).\n", .{signed_count});
        try stdout.flush();
    }

    try stdout.print("Updating trust database...\n", .{});
    try stdout.flush();
    try gpg_cli.checkTrustdb();
}

pub fn recvKeys(
    io: Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
    gpgdir: []const u8,
    key_ids: []const []const u8,
    keyserver: ?[]const u8,
    user_mode: bool,
    stdout: *Io.Writer,
) !void {
    if (!user_mode) try elevate.ensureRoot(io, allocator, args, path_env);

    if (key_ids.len == 0) return error.NoTargetsSpecified;

    const gpg_cli: gpg.Gpg = .{ .io = io, .homedir = if (user_mode) null else gpgdir };

    try gpg_cli.recvKeys(keyserver, key_ids);

    // Evaluate trust for the freshly received keys, as pacman-key does.
    if (!user_mode) {
        try stdout.print("Updating trust database...\n", .{});
        try stdout.flush();
        try gpg_cli.checkTrustdb();
    }
}

pub fn refreshKeys(
    io: Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
    gpgdir: []const u8,
    key_ids: []const []const u8,
    keyserver: ?[]const u8,
    user_mode: bool,
    stdout: *Io.Writer,
) !void {
    if (!user_mode) try elevate.ensureRoot(io, allocator, args, path_env);

    const gpg_cli: gpg.Gpg = .{ .io = io, .homedir = if (user_mode) null else gpgdir };

    if (key_ids.len > 0) try checkKeyIdsExist(allocator, gpg_cli, key_ids);

    const master_keys = try collectMasterKeys(allocator, gpg_cli);
    defer {
        for (master_keys) |id| allocator.free(id);
        allocator.free(master_keys);
    }

    const ids = try listPublicKeyIds(allocator, gpg_cli, key_ids);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }

    var had_failure = false;
    for (ids) |id| {
        if (isMasterKey(master_keys, id)) continue;

        try stdout.print("Refreshing key {s}...\n", .{id});
        try stdout.flush();

        if (try refreshSingleKey(allocator, gpg_cli, keyserver, id)) continue;

        try stdout.print("Could not update key: {s}\n", .{id});
        try stdout.flush();
        had_failure = true;
    }

    if (had_failure) return error.GpgFailed;
}

pub fn populate(
    io: Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    env_map: *const std.process.Environ.Map,
    gpgdir: []const u8,
    populate_from: []const u8,
    requested: []const []const u8,
    stdout: *Io.Writer,
) !void {
    try elevate.ensureRoot(io, allocator, args, env_map.get("PATH").?);

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
        try locallySignKeys(gpg_cli, stdout, &keys_to_sign);

        try importOwnertrust(
            gpg_cli,
            base,
            io,
            populate_from,
            keyring_ids,
            stdout,
        );
    }

    try disableRevokedKeys(
        allocator,
        gpg_cli,
        env_map,
        base,
        io,
        populate_from,
        keyring_ids,
        stdout,
    );

    try stdout.print("Updating trust database...\n", .{});
    try stdout.flush();
    try gpg_cli.checkTrustdb();
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
    gpg_cli: gpg.Gpg,
    stdout: *Io.Writer,
    keys_to_sign: *const std.StringHashMap(void),
) !void {
    try stdout.print("Locally signing trusted keys in keyring...\n", .{});
    try stdout.flush();

    var it = keys_to_sign.iterator();
    while (it.next()) |entry| {
        try stdout.print("  Locally signing key {s}...\n", .{entry.key_ptr.*});
        try stdout.flush();
        try gpg_cli.locallySignKey(entry.key_ptr.*);
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

fn disableRevokedKeys(
    allocator: std.mem.Allocator,
    gpg_cli: gpg.Gpg,
    env_map: *const std.process.Environ.Map,
    base: std.Io.Dir,
    io: Io,
    populate_from: []const u8,
    keyring_ids: []const []const u8,
    stdout: *Io.Writer,
) !void {
    var keys_to_disable = std.StringHashMap(void).init(allocator);
    defer {
        var it = keys_to_disable.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        keys_to_disable.deinit();
    }

    for (keyring_ids) |id| {
        const revoked = try keyfiles.readRevokedFingerprints(
            allocator,
            base,
            io,
            populate_from,
            id,
        );
        defer {
            for (revoked) |fp| allocator.free(fp);
            allocator.free(revoked);
        }

        for (revoked) |fp| {
            if (keys_to_disable.contains(fp)) continue;
            if (try gpg_cli.keyIsRevoked(allocator, fp)) continue;
            const owned = try allocator.dupe(u8, fp);
            try keys_to_disable.put(owned, {});
        }
    }

    if (keys_to_disable.count() == 0) return;

    try stdout.print("Disabling revoked keys in keyring...\n", .{});
    try stdout.flush();

    var it = keys_to_disable.iterator();
    while (it.next()) |entry| {
        try stdout.print("  Disabling key {s}...\n", .{entry.key_ptr.*});
        try stdout.flush();
        try gpg_cli.disableKey(allocator, env_map, entry.key_ptr.*);
    }

    try stdout.print("  Disabled {d} key(s).\n", .{keys_to_disable.count()});
    try stdout.flush();
}

fn ensureKeyExists(allocator: std.mem.Allocator, gpg_cli: gpg.Gpg, key_id: []const u8) !void {
    const output = try gpg_cli.runCapture(allocator, &.{
        "--with-colons", "--list-key", "--quiet", key_id,
    });
    defer allocator.free(output);
}

fn checkKeyIdsExist(
    allocator: std.mem.Allocator,
    gpg_cli: gpg.Gpg,
    key_ids: []const []const u8,
) !void {
    for (key_ids) |key_id| {
        _ = gpg_cli.runCapture(allocator, &.{ "--list-keys", "--quiet", key_id }) catch
            return error.KeyNotFoundLocally;
    }
}

fn isMasterKey(master_keys: []const []const u8, id: []const u8) bool {
    for (master_keys) |master_key| {
        if (std.mem.eql(u8, master_key, id)) return true;
    }
    return false;
}

fn pubKeyIdsFromListing(allocator: std.mem.Allocator, output: []const u8) ![][]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (!std.mem.eql(u8, gpg.colonField(line, 0), "pub")) continue;
        const id = gpg.colonField(line, 4);
        if (id.len == 0) continue;
        try ids.append(allocator, try allocator.dupe(u8, id));
    }

    return ids.toOwnedSlice(allocator);
}

fn collectMasterKeys(allocator: std.mem.Allocator, gpg_cli: gpg.Gpg) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |id| allocator.free(id);
        keys.deinit(allocator);
    }

    for ([_][]const u8{ master_key_uid, legacy_master_key_uid }) |uid| {
        // A keyring without that master key must not block refreshing;
        // pacman-key likewise ends up with an empty exclusion list here.
        const output = gpg_cli.runCapture(allocator, &.{
            "--with-colons", "--list-keys", "--quiet", uid,
        }) catch |err| switch (err) {
            error.GpgFailed => continue,
            else => |e| return e,
        };
        defer allocator.free(output);

        const ids = try pubKeyIdsFromListing(allocator, output);
        defer allocator.free(ids);
        for (ids) |id| try keys.append(allocator, id);
    }

    return keys.toOwnedSlice(allocator);
}

fn listPublicKeyIds(
    allocator: std.mem.Allocator,
    gpg_cli: gpg.Gpg,
    patterns: []const []const u8,
) ![][]const u8 {
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(allocator);
    try extra.appendSlice(allocator, &.{ "--with-colons", "--list-keys", "--quiet" });
    try extra.appendSlice(allocator, patterns);

    // Nothing matches (e.g. an empty keyring for a global refresh): refresh no
    // keys instead of failing, matching pacman-key's silent no-op.
    const output = gpg_cli.runCapture(allocator, extra.items) catch |err| switch (err) {
        error.GpgFailed => return &.{},
        else => |e| return e,
    };
    defer allocator.free(output);

    return pubKeyIdsFromListing(allocator, output);
}

/// Collect the mailboxes (`show-only-fpr-mbox`) of every uid on `id`.
fn collectMboxes(allocator: std.mem.Allocator, gpg_cli: gpg.Gpg, id: []const u8) ![][]const u8 {
    const output = gpg_cli.runCapture(allocator, &.{
        "--list-options", "show-only-fpr-mbox", id,
    }) catch |err| switch (err) {
        error.GpgFailed => return &.{},
        else => |e| return e,
    };
    defer allocator.free(output);

    var mboxes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (mboxes.items) |mbox| allocator.free(mbox);
        mboxes.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
        _ = fields.next() orelse continue; // fingerprint; we refresh via the mailbox
        const mbox = fields.next() orelse continue;
        try mboxes.append(allocator, try allocator.dupe(u8, mbox));
    }

    return mboxes.toOwnedSlice(allocator);
}

/// Refresh one key: WKD lookup by mailbox first, keyserver fallback second.
/// Returns false when every lookup failed.
fn refreshSingleKey(
    allocator: std.mem.Allocator,
    gpg_cli: gpg.Gpg,
    keyserver: ?[]const u8,
    id: []const u8,
) !bool {
    const mboxes = try collectMboxes(allocator, gpg_cli, id);
    defer {
        for (mboxes) |mbox| allocator.free(mbox);
        allocator.free(mboxes);
    }

    for (mboxes) |mbox| {
        gpg_cli.locateExternalKeys(mbox) catch |err| switch (err) {
            error.GpgFailed => continue,
            else => |e| return e,
        };
        return true;
    }

    gpg_cli.refreshKeys(keyserver, id) catch |err| switch (err) {
        error.GpgFailed => return false,
        else => |e| return e,
    };
    return true;
}
