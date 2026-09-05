const std = @import("std");
const Zigalpm = @import("Zigalpm");

pub fn containsKey(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, fingerprint: []const u8) !bool {
    try Zigalpm.source_pgp_verifier.validatePinnedKeys(&.{fingerprint});
    const result = try run(allocator, io, environ, &.{ "/usr/bin/gpg", "--batch", "--no-tty", "--list-keys", fingerprint });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return succeeded(result.term);
}

/// Export only the public keys pinned by the evaluated, approved PKGBUILD.
/// An empty selection must not become GnuPG's request to export every key.
pub fn exportKeys(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, fingerprints: []const []const u8) ![]u8 {
    try Zigalpm.source_pgp_verifier.validatePinnedKeys(fingerprints);
    if (fingerprints.len == 0) return allocator.dupe(u8, "");
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    try arguments.appendSlice(allocator, &.{ "/usr/bin/gpg", "--batch", "--no-tty", "--armor", "--export" });
    try arguments.appendSlice(allocator, fingerprints);
    const result = try run(allocator, io, environ, arguments.items);
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (!succeeded(result.term) or result.stdout.len == 0) return error.PgpKeyExportFailed;
    return result.stdout;
}

/// Import into the guest user's own keyring, never the coordinator's keyring.
pub fn importKeys(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, path: []const u8) !void {
    const result = try run(allocator, io, environ, &.{
        "/usr/bin/gpg", "--batch", "--no-tty", "--import", path,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!succeeded(result.term)) return error.PgpKeyImportFailed;
}

fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, arguments: []const []const u8) !std.process.RunResult {
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    return std.process.run(allocator, io, .{
        .argv = arguments,
        .environ_map = &environment,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } },
    });
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "isolated source public keys reach a clean guest and signatures remain enforced" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    try temporary.dir.createDir(io, "host", .fromMode(0o700));
    try temporary.dir.createDir(io, "guest", .fromMode(0o700));
    try temporary.dir.createDir(io, "host/.gnupg", .fromMode(0o700));
    try temporary.dir.createDir(io, "guest/.gnupg", .fromMode(0o700));
    // Public-key fixtures need no agent and must not leave daemons behind.
    try temporary.dir.writeFile(io, .{ .sub_path = "host/.gnupg/gpg.conf", .data = "no-autostart\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "guest/.gnupg/gpg.conf", .data = "no-autostart\n" });
    const host_path = try std.fs.path.join(allocator, &.{ directory, "host" });
    defer allocator.free(host_path);
    const guest_path = try std.fs.path.join(allocator, &.{ directory, "guest" });
    defer allocator.free(guest_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", host_path);
    const host: std.process.Environ = .{ .block = try environment.createPosixBlock(allocator, .{}) };
    defer host.block.deinit(allocator);
    try environment.put("HOME", guest_path);
    const guest: std.process.Environ = .{ .block = try environment.createPosixBlock(allocator, .{}) };
    defer guest.block.deinit(allocator);
    const fingerprint = "2E37DFCC9287C8A2F84B2519241A5B24548FAC70";
    try temporary.dir.writeFile(io, .{ .sub_path = "public.asc", .data = @embedFile("fixtures/source-pgp/public.asc") });
    const key_path = try std.fs.path.join(allocator, &.{ directory, "public.asc" });
    defer allocator.free(key_path);
    try importKeys(allocator, io, host, key_path);
    try std.testing.expect(try containsKey(allocator, io, host, fingerprint));
    try std.testing.expect(!(try containsKey(allocator, io, guest, fingerprint)));
    const empty = try exportKeys(allocator, io, host, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidPgpFingerprint, exportKeys(allocator, io, host, &.{"--export-secret-keys"}));
    const bundle = try exportKeys(allocator, io, host, &.{fingerprint});
    defer allocator.free(bundle);
    try std.testing.expect(std.mem.startsWith(u8, bundle, "-----BEGIN PGP PUBLIC KEY BLOCK-----"));
    try temporary.dir.writeFile(io, .{ .sub_path = "public.asc", .data = bundle });
    try importKeys(allocator, io, guest, key_path);
    try std.testing.expect(try containsKey(allocator, io, guest, fingerprint));
    const secret_keys = try run(allocator, io, guest, &.{ "/usr/bin/gpg", "--batch", "--no-autostart", "--with-colons", "--list-secret-keys" });
    defer allocator.free(secret_keys.stdout);
    defer allocator.free(secret_keys.stderr);
    try std.testing.expect(std.mem.indexOf(u8, secret_keys.stdout, "sec:") == null);

    try temporary.dir.writeFile(io, .{ .sub_path = "payload.txt", .data = @embedFile("fixtures/source-pgp/payload.txt") });
    try temporary.dir.writeFile(io, .{ .sub_path = "payload.sig", .data = @embedFile("fixtures/source-pgp/payload.sig") });
    const payload = try std.fs.path.join(allocator, &.{ directory, "payload.txt" });
    defer allocator.free(payload);
    const signature = try std.fs.path.join(allocator, &.{ directory, "payload.sig" });
    defer allocator.free(signature);
    const verifier: Zigalpm.source_pgp_verifier.Verifier = .{ .allocator = allocator, .io = io, .environ = guest };
    var verified = try verifier.verifyDetached(signature, payload, &.{fingerprint});
    defer verified.deinit(allocator);
    try std.testing.expectEqualStrings(fingerprint, verified.primary_fingerprint);
    try std.testing.expectError(error.InvalidPgpKey, verifier.verifyDetached(signature, payload, &.{"5A" ** 20}));
    try temporary.dir.writeFile(io, .{ .sub_path = "payload.txt", .data = "tampered\n" });
    try std.testing.expectError(error.BadPgpSignature, verifier.verifyDetached(signature, payload, &.{fingerprint}));
}
