const std = @import("std");

pub const Warning = enum {
    none,
    expired_signature,
    expired_key,
};

pub const Verification = struct {
    primary_fingerprint: []u8,
    warning: Warning,

    pub fn deinit(self: *Verification, allocator: std.mem.Allocator) void {
        allocator.free(self.primary_fingerprint);
        self.* = undefined;
    }
};

pub const GitObject = enum {
    commit,
    tag,
};

/// Reusable OpenPGP verifier for staged source files and signed Git objects.
/// It never evaluates a shell command and only interprets GnuPG's status-fd
/// protocol. Callers remain responsible for source pairing and decompression.
pub const Verifier = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    gpg_path: []const u8 = "/usr/bin/gpg",
    git_path: []const u8 = "/usr/bin/git",
    gnupg_home: ?[]const u8 = null,
    timeout_seconds: u32 = 60,

    pub fn verifyDetached(
        self: Verifier,
        signature_path: []const u8,
        payload_path: []const u8,
        valid_pgp_keys: []const []const u8,
    ) !Verification {
        try validatePinnedKeys(valid_pgp_keys);
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(self.allocator);
        try arguments.appendSlice(self.allocator, &.{ self.gpg_path, "--quiet", "--batch", "--no-tty" });
        if (self.gnupg_home) |home|
            try arguments.appendSlice(self.allocator, &.{ "--homedir", home });
        try arguments.appendSlice(self.allocator, &.{ "--status-fd=1", "--verify", signature_path, payload_path });
        var result = try self.run(arguments.items, null);
        defer result.deinit(self.allocator);
        const status = try std.mem.concat(self.allocator, u8, &.{ result.stdout, "\n", result.stderr });
        defer self.allocator.free(status);
        return evaluateStatus(self.allocator, status, result.exit_code, valid_pgp_keys);
    }

    pub fn verifyGit(
        self: Verifier,
        repository_path: []const u8,
        object: GitObject,
        reference: []const u8,
        valid_pgp_keys: []const []const u8,
    ) !Verification {
        try validatePinnedKeys(valid_pgp_keys);
        const subcommand = switch (object) {
            .commit => "verify-commit",
            .tag => "verify-tag",
        };
        var result = try self.run(&.{
            self.git_path,
            "-C",
            repository_path,
            subcommand,
            "--raw",
            reference,
        }, null);
        defer result.deinit(self.allocator);
        const status = try std.mem.concat(self.allocator, u8, &.{ result.stdout, "\n", result.stderr });
        defer self.allocator.free(status);
        return evaluateStatus(self.allocator, status, result.exit_code, valid_pgp_keys);
    }

    fn run(self: Verifier, argv: []const []const u8, cwd: ?[]const u8) !CommandResult {
        var environment = try self.environ.createMap(self.allocator);
        defer environment.deinit();
        if (self.gnupg_home) |home| try environment.put("GNUPGHOME", home);
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &environment,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(self.timeout_seconds) } },
        });
        return .{
            .exit_code = switch (result.term) {
                .exited => |code| code,
                else => 255,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }
};

const CommandResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn validatePinnedKeys(keys: []const []const u8) !void {
    for (keys) |key| {
        if (key.len != 40 and key.len != 64) return error.InvalidPgpFingerprint;
        for (key) |character| {
            if (!std.ascii.isHex(character) or std.ascii.isLower(character))
                return error.InvalidPgpFingerprint;
        }
    }
}

/// Mirrors makepkg's parse_gpg_statusfile: signature records are evaluated
/// sequentially and later records override earlier ones, so a dual-signed
/// artifact passes when a later signature is good and pinned even if an
/// earlier signature referenced a key that is not present. NO_PUBKEY carries
/// no decision on its own — makepkg's status filter drops it, and a missing
/// key is classified through ERRSIG's return code instead.
pub fn evaluateStatus(
    allocator: std.mem.Allocator,
    status_output: []const u8,
    exit_code: u8,
    valid_pgp_keys: []const []const u8,
) !Verification {
    try validatePinnedKeys(valid_pgp_keys);
    var saw_new_signature = false;
    var status: signature_status = .none;
    var trusted = false;
    var fingerprint: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, status_output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[GNUPG:] ")) continue;
        var fields = std.mem.tokenizeAny(u8, line["[GNUPG:] ".len..], " \t");
        const record = fields.next() orelse continue;
        if (std.mem.eql(u8, record, "NEWSIG")) {
            saw_new_signature = true;
        } else if (std.mem.eql(u8, record, "GOODSIG")) {
            status = .good;
        } else if (std.mem.eql(u8, record, "EXPSIG")) {
            status = .expired_signature;
        } else if (std.mem.eql(u8, record, "EXPKEYSIG")) {
            status = .expired_key;
        } else if (std.mem.eql(u8, record, "REVKEYSIG")) {
            status = .revoked_key;
        } else if (std.mem.eql(u8, record, "BADSIG")) {
            status = .bad;
        } else if (std.mem.eql(u8, record, "ERRSIG")) {
            var field_index: usize = 0;
            var return_code: ?[]const u8 = null;
            while (fields.next()) |value| : (field_index += 1) {
                if (field_index == 5) {
                    return_code = value;
                    break;
                }
            }
            status = if (return_code != null and std.mem.eql(u8, return_code.?, "9"))
                .missing_key
            else
                .verification_error;
        } else if (std.mem.eql(u8, record, "VALIDSIG")) {
            var values: [10]?[]const u8 = .{null} ** 10;
            var count: usize = 0;
            while (fields.next()) |value| {
                if (count < values.len) values[count] = value;
                count += 1;
            }
            fingerprint = if (count >= 10 and values[9].?.len != 0) values[9] else values[0];
        } else if (std.mem.eql(u8, record, "TRUST_MARGINAL") or
            std.mem.eql(u8, record, "TRUST_FULLY") or
            std.mem.eql(u8, record, "TRUST_ULTIMATE"))
        {
            trusted = true;
        } else if (std.mem.eql(u8, record, "TRUST_UNDEFINED") or
            std.mem.eql(u8, record, "TRUST_NEVER"))
        {
            trusted = false;
        }
    }

    if (!saw_new_signature) return error.MissingPgpSignature;
    // makepkg decides from GnuPG's machine-readable status records. In
    // particular, expired signatures can be accepted with a warning even if
    // the command's process status is non-zero.
    _ = exit_code;
    switch (status) {
        .none, .verification_error => return error.PgpVerificationFailed,
        .revoked_key => return error.RevokedPgpKey,
        .bad => return error.BadPgpSignature,
        .missing_key => return error.MissingPgpKey,
        .good, .expired_signature, .expired_key => {},
    }
    const primary = fingerprint orelse return error.InvalidPgpStatus;
    if (valid_pgp_keys.len > 0) {
        var pinned = false;
        for (valid_pgp_keys) |key| {
            if (std.mem.eql(u8, key, primary)) {
                pinned = true;
                break;
            }
        }
        if (!pinned) return error.InvalidPgpKey;
    } else if (!trusted) return error.UntrustedPgpKey;

    return .{
        .primary_fingerprint = try allocator.dupe(u8, primary),
        .warning = switch (status) {
            .expired_signature => .expired_signature,
            .expired_key => .expired_key,
            else => .none,
        },
    };
}

const signature_status = enum {
    none,
    good,
    expired_signature,
    expired_key,
    revoked_key,
    bad,
    missing_key,
    verification_error,
};

test "source PGP status accepts a pinned primary key used through a subkey" {
    const primary = "0123456789ABCDEF0123456789ABCDEF01234567";
    const status =
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] GOODSIG 89ABCDEF01234567 Test User\n" ++
        "[GNUPG:] VALIDSIG 89ABCDEF0123456789ABCDEF0123456789ABCDEF 2026-01-01 0 0 4 0 1 10 00 " ++ primary ++ "\n" ++
        "[GNUPG:] TRUST_UNDEFINED 0 pgp\n";
    var verification = try evaluateStatus(std.testing.allocator, status, 0, &.{primary});
    defer verification.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(primary, verification.primary_fingerprint);
}

test "source PGP status requires trust without pins" {
    const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
    const base =
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] GOODSIG 89ABCDEF01234567 Test User\n" ++
        "[GNUPG:] VALIDSIG " ++ fingerprint ++ " 2026-01-01 0 0 4 0 1 10 00\n";
    try std.testing.expectError(
        error.UntrustedPgpKey,
        evaluateStatus(std.testing.allocator, base ++ "[GNUPG:] TRUST_UNDEFINED 0 pgp\n", 0, &.{}),
    );
    var verification = try evaluateStatus(
        std.testing.allocator,
        base ++ "[GNUPG:] TRUST_FULLY 0 pgp\n",
        0,
        &.{},
    );
    defer verification.deinit(std.testing.allocator);
}

test "source PGP status rejects bad missing and unpinned signatures" {
    const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
    try std.testing.expectError(
        error.BadPgpSignature,
        evaluateStatus(std.testing.allocator, "[GNUPG:] NEWSIG\n[GNUPG:] BADSIG DEADBEEF bad\n", 1, &.{fingerprint}),
    );
    // makepkg's status filter drops NO_PUBKEY records, so one without an
    // accompanying ERRSIG degrades to a generic verification failure.
    try std.testing.expectError(
        error.PgpVerificationFailed,
        evaluateStatus(std.testing.allocator, "[GNUPG:] NEWSIG\n[GNUPG:] NO_PUBKEY DEADBEEF\n", 2, &.{fingerprint}),
    );
    try std.testing.expectError(
        error.MissingPgpKey,
        evaluateStatus(
            std.testing.allocator,
            "[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG DEADBEEF 22 8 00 0 9\n",
            2,
            &.{fingerprint},
        ),
    );
    const other = "89ABCDEF0123456789ABCDEF0123456789ABCDEF";
    const status =
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] GOODSIG DEADBEEF good\n" ++
        "[GNUPG:] VALIDSIG " ++ other ++ " 2026-01-01 0 0 4 0 1 10 00\n";
    try std.testing.expectError(
        error.InvalidPgpKey,
        evaluateStatus(std.testing.allocator, status, 0, &.{fingerprint}),
    );
}

test "source PGP status accepts dual-signed artifacts when the pinned signature is good" {
    // Real status output for sdl2-compat-2.32.72.tar.gz.sig: the release is
    // signed by a new key that is not in validpgpkeys and by the pinned key.
    // makepkg accepts it because the later GOODSIG overrides the earlier
    // ERRSIG; Shelly previously failed the whole build with MissingPgpKey.
    const pinned = "0900104363B4C9D4223DE149D913FE7D4B61D39B";
    const status =
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] ERRSIG 30A59377A7763BE6 17 2 00 1788368120 9 1528635D8053A57F77D1E08630A59377A7763BE6\n" ++
        "[GNUPG:] NO_PUBKEY 30A59377A7763BE6\n" ++
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] KEY_CONSIDERED " ++ pinned ++ " 0\n" ++
        "[GNUPG:] SIG_ID T06SwK95Z19UH/CTAzqR5PPShPo 2026-09-02 1788368120\n" ++
        "[GNUPG:] GOODSIG D913FE7D4B61D39B Sam Lantinga <slouken@libsdl.org>\n" ++
        "[GNUPG:] VALIDSIG " ++ pinned ++ " 2026-09-02 1788368120 0 4 0 1 8 00 " ++ pinned ++ "\n" ++
        "[GNUPG:] TRUST_UNDEFINED 0 pgp\n" ++
        "[GNUPG:] FAILURE gpg-exit 33554433\n";
    var verification = try evaluateStatus(std.testing.allocator, status, 2, &.{pinned});
    defer verification.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(pinned, verification.primary_fingerprint);
    try std.testing.expectEqual(Warning.none, verification.warning);
}

test "source PGP status keeps the last signature verdict like makepkg" {
    const pinned = "0900104363B4C9D4223DE149D913FE7D4B61D39B";
    const good_first =
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] GOODSIG D913FE7D4B61D39B Sam Lantinga <slouken@libsdl.org>\n" ++
        "[GNUPG:] VALIDSIG " ++ pinned ++ " 2026-09-02 1788368120 0 4 0 1 8 00 " ++ pinned ++ "\n";
    // A later ERRSIG with a missing key overrides the earlier good signature,
    // matching makepkg's sequential parse.
    try std.testing.expectError(
        error.MissingPgpKey,
        evaluateStatus(
            std.testing.allocator,
            good_first ++ "[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 30A59377A7763BE6 17 2 00 1788368120 9\n",
            2,
            &.{pinned},
        ),
    );
    try std.testing.expectError(
        error.PgpVerificationFailed,
        evaluateStatus(
            std.testing.allocator,
            good_first ++ "[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 30A59377A7763BE6 17 2 00 1788368120 4\n",
            2,
            &.{pinned},
        ),
    );
    try std.testing.expectError(
        error.BadPgpSignature,
        evaluateStatus(
            std.testing.allocator,
            good_first ++ "[GNUPG:] NEWSIG\n[GNUPG:] BADSIG 30A59377A7763BE6 bad\n",
            2,
            &.{pinned},
        ),
    );
}

test "source PGP status derives the warning from the final signature verdict" {
    const pinned = "0900104363B4C9D4223DE149D913FE7D4B61D39B";
    var expired = try evaluateStatus(
        std.testing.allocator,
        "[GNUPG:] NEWSIG\n" ++
            "[GNUPG:] EXPSIG D913FE7D4B61D39B Sam Lantinga <slouken@libsdl.org>\n" ++
            "[GNUPG:] VALIDSIG " ++ pinned ++ " 2026-09-02 1788368120 0 4 0 1 8 00 " ++ pinned ++ "\n",
        0,
        &.{pinned},
    );
    defer expired.deinit(std.testing.allocator);
    try std.testing.expectEqual(Warning.expired_signature, expired.warning);

    // A later bad signature suppresses the expired-signature warning.
    try std.testing.expectError(
        error.BadPgpSignature,
        evaluateStatus(
            std.testing.allocator,
            "[GNUPG:] NEWSIG\n" ++
                "[GNUPG:] EXPSIG D913FE7D4B61D39B Sam Lantinga <slouken@libsdl.org>\n" ++
                "[GNUPG:] NEWSIG\n" ++
                "[GNUPG:] BADSIG D913FE7D4B61D39B bad\n",
            2,
            &.{pinned},
        ),
    );
}

test "source PGP pin validation requires full uppercase fingerprints" {
    try std.testing.expectError(error.InvalidPgpFingerprint, validatePinnedKeys(&.{"deadbeef"}));
    try std.testing.expectError(
        error.InvalidPgpFingerprint,
        validatePinnedKeys(&.{"0123456789abcdef0123456789abcdef01234567"}),
    );
}

fn importGpgFixture(arguments: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = arguments,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term == .exited and (result.term.exited == 0 or
        std.mem.indexOf(u8, result.stdout, "[GNUPG:] IMPORT_OK") != null)) return;
    std.debug.print("GnuPG fixture failed: {s}\n", .{result.stderr});
    return error.GpgFixtureFailed;
}

test "source PGP verifier validates pinned-untrusted detached signatures without private keys" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const fingerprint = "2E37DFCC9287C8A2F84B2519241A5B24548FAC70";
    const public_key_base64 = "LS0tLS1CRUdJTiBQR1AgUFVCTElDIEtFWSBCTE9DSy0tLS0tCgptRE1FYW9OTXZ4WUpLd1lCQkFIYVJ3OEJBUWRBM0RFdFI5MXZLRU4zcXVsTmJBWVh2Z2EvRWl5K1VoQTMxeVBKCjcwZGlvbzIwTUZOb1pXeHNlU0JUYjNWeVkyVWdWR1Z6ZENBOGMyOTFjbU5sTFhSbGMzUkFaWGhoYlhCc1pTNXAKYm5aaGJHbGtQb2lRQkJNV0NnQTRGaUVFTGpmZnpKS0h5S0w0U3lVWkpCcGJKRlNQckhBRkFtcURUTDhDR3dNRgpDd2tJQndJR0ZRb0pDQXNDQkJZQ0F3RUNIZ0VDRjRBQUNna1FKQnBiSkZTUHJIQnJnUUVBbVFEdkNMNHZoc01CClgya3Y2V3ZFN1pMVzgyaUZQbkJaR2U1SXpDYWVvdUlCQVBMRC80M2RmbGlxZkVFTzFFZktJQVQ5SjV3cXdldmUKdFRBdXFvVGFRUXNLCj1jbzViCi0tLS0tRU5EIFBHUCBQVUJMSUMgS0VZIEJMT0NLLS0tLS0K";
    const signature_base64 = "iHUEABYKAB0WIQQuN9/MkofIovhLJRkkGlskVI+scAUCaoNNkwAKCRAkGlskVI+scBdcAP91A7dSPdze1V9Nmg8WM8/fQ1ok2OdwBK5tSxyvKX4OeQEA16pbB6X6y/DarBoa3OaU5Up21xdPZL1g+3o2i1xztgM=";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "verifier", .fromMode(0o700));
    try temporary.dir.createDir(io, "missing", .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "payload", .data = "authenticated payload\n" });
    const public_key_size = try std.base64.standard.Decoder.calcSizeForSlice(public_key_base64);
    const public_key_contents = try allocator.alloc(u8, public_key_size);
    defer allocator.free(public_key_contents);
    try std.base64.standard.Decoder.decode(public_key_contents, public_key_base64);
    try temporary.dir.writeFile(io, .{ .sub_path = "public.asc", .data = public_key_contents });
    const signature_size = try std.base64.standard.Decoder.calcSizeForSlice(signature_base64);
    const signature_contents = try allocator.alloc(u8, signature_size);
    defer allocator.free(signature_contents);
    try std.base64.standard.Decoder.decode(signature_contents, signature_base64);
    try temporary.dir.writeFile(io, .{ .sub_path = "payload.sig", .data = signature_contents });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const verifier_home = try std.fs.path.join(allocator, &.{ root, "verifier" });
    defer allocator.free(verifier_home);
    const missing_home = try std.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing_home);
    const payload = try std.fs.path.join(allocator, &.{ root, "payload" });
    defer allocator.free(payload);
    const signature = try std.fs.path.join(allocator, &.{ root, "payload.sig" });
    defer allocator.free(signature);
    const public_key = try std.fs.path.join(allocator, &.{ root, "public.asc" });
    defer allocator.free(public_key);

    try importGpgFixture(&.{
        "/usr/bin/gpg",
        "--homedir",
        verifier_home,
        "--batch",
        "--no-autostart",
        "--status-fd=1",
        "--import",
        public_key,
    });

    var pinned = try (Verifier{
        .allocator = allocator,
        .io = io,
        .environ = std.testing.environ,
        .gnupg_home = verifier_home,
    }).verifyDetached(signature, payload, &.{fingerprint});
    defer pinned.deinit(allocator);
    try std.testing.expectEqualStrings(fingerprint, pinned.primary_fingerprint);
    try std.testing.expectError(
        error.UntrustedPgpKey,
        (Verifier{
            .allocator = allocator,
            .io = io,
            .environ = std.testing.environ,
            .gnupg_home = verifier_home,
        }).verifyDetached(signature, payload, &.{}),
    );
    try std.testing.expectError(
        error.MissingPgpKey,
        (Verifier{
            .allocator = allocator,
            .io = io,
            .environ = std.testing.environ,
            .gnupg_home = missing_home,
        }).verifyDetached(signature, payload, &.{fingerprint}),
    );

    try temporary.dir.writeFile(io, .{ .sub_path = "payload", .data = "tampered payload\n" });
    try std.testing.expectError(
        error.BadPgpSignature,
        (Verifier{
            .allocator = allocator,
            .io = io,
            .environ = std.testing.environ,
            .gnupg_home = verifier_home,
        }).verifyDetached(signature, payload, &.{fingerprint}),
    );
}
