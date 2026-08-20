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

pub fn evaluateStatus(
    allocator: std.mem.Allocator,
    status_output: []const u8,
    exit_code: u8,
    valid_pgp_keys: []const []const u8,
) !Verification {
    try validatePinnedKeys(valid_pgp_keys);
    var saw_new_signature = false;
    var successful = false;
    var trusted = false;
    var warning: Warning = .none;
    var fingerprint: ?[]const u8 = null;
    var failure: ?anyerror = null;

    var lines = std.mem.splitScalar(u8, status_output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "[GNUPG:] ")) continue;
        var fields = std.mem.tokenizeAny(u8, line["[GNUPG:] ".len..], " \t");
        const record = fields.next() orelse continue;
        if (std.mem.eql(u8, record, "NEWSIG")) {
            saw_new_signature = true;
        } else if (std.mem.eql(u8, record, "GOODSIG")) {
            successful = true;
        } else if (std.mem.eql(u8, record, "EXPSIG")) {
            successful = true;
            warning = .expired_signature;
        } else if (std.mem.eql(u8, record, "EXPKEYSIG")) {
            successful = true;
            warning = .expired_key;
        } else if (std.mem.eql(u8, record, "REVKEYSIG")) {
            successful = false;
            failure = error.RevokedPgpKey;
        } else if (std.mem.eql(u8, record, "BADSIG")) {
            successful = false;
            failure = error.BadPgpSignature;
        } else if (std.mem.eql(u8, record, "NO_PUBKEY")) {
            successful = false;
            failure = error.MissingPgpKey;
        } else if (std.mem.eql(u8, record, "ERRSIG")) {
            successful = false;
            var field_index: usize = 0;
            var return_code: ?[]const u8 = null;
            while (fields.next()) |value| : (field_index += 1) {
                if (field_index == 5) {
                    return_code = value;
                    break;
                }
            }
            failure = if (return_code != null and std.mem.eql(u8, return_code.?, "9"))
                error.MissingPgpKey
            else
                error.PgpVerificationFailed;
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

    if (failure) |err| return err;
    if (!saw_new_signature) return error.MissingPgpSignature;
    // makepkg decides from GnuPG's machine-readable status records. In
    // particular, expired signatures can be accepted with a warning even if
    // the command's process status is non-zero.
    _ = exit_code;
    if (!successful) return error.PgpVerificationFailed;
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
        .warning = warning,
    };
}

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
    try std.testing.expectError(
        error.MissingPgpKey,
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
