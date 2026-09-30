const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");

const Database = rlpm.Database;

const SignatureFixture = struct {
    temporary: TemporaryHome,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    signer_home: []const u8,
    verifier_home: []const u8,
    unknown_home: []const u8,

    const contents = "Shelly database signature fixture\n\x00\x01\x02\xff";
    const identity = "Shelly Signature Tests <signature-tests@example.invalid>";

    fn init() !SignatureFixture {
        // An explicitly requested integration target must fail when tools are absent.
        for ([_][]const u8{ "gpg", "gpgconf", "gpg-agent" }) |executable| {
            runCommand(&.{ executable, "--version" }, .inherit) catch |err| switch (err) {
                error.FileNotFound => {
                    std.debug.print("integration test requires {s}\n", .{executable});
                    return error.GpgIntegrationUnavailable;
                },
                else => return err,
            };
        }

        var temporary = try TemporaryHome.init();
        errdefer cleanupTemporary(&temporary) catch |err| {
            std.log.err("failed to remove signature fixture: {t}", .{err});
        };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        const signer_home = try std.fs.path.join(allocator, &.{ path, "signer" });
        const verifier_home = try std.fs.path.join(allocator, &.{ path, "verifier" });
        const unknown_home = try std.fs.path.join(allocator, &.{ path, "unknown" });
        for ([_][]const u8{ "signer", "verifier", "unknown" }) |name| {
            try temporary.dir.createDir(std.testing.io, name, .fromMode(0o700));
            // Verification cannot fetch keys or start extra agents.
            if (!std.mem.eql(u8, name, "signer")) {
                const config_path = try std.fs.path.join(allocator, &.{ name, "gpg.conf" });
                try temporary.dir.writeFile(std.testing.io, .{
                    .sub_path = config_path,
                    .data = "no-auto-key-retrieve\nno-auto-key-import\nno-autostart\n",
                });
            }
        }

        const fixture: SignatureFixture = .{
            .temporary = temporary,
            .arena = arena,
            .path = path,
            .signer_home = signer_home,
            .verifier_home = verifier_home,
            .unknown_home = unknown_home,
        };
        // Also stop agents if key generation or any later setup operation fails.
        errdefer fixture.stopAgents() catch |err| {
            std.log.err("failed to stop fixture GPG agents: {t}", .{err});
        };

        runCommand(&.{ "gpgconf", "--homedir", signer_home, "--launch", "gpg-agent" }, .inherit) catch {
            std.debug.print(
                "GPG integration requires permission to start an agent and bind its Unix sockets\n",
                .{},
            );
            return error.GpgIntegrationUnavailable;
        };

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "test.db",
            .data = contents,
        });
        try fixture.runGpg(signer_home, &.{
            "--pinentry-mode",      "loopback", "--passphrase", "",
            "--quick-generate-key", identity,   "ed25519",      "sign",
            "0",
        });
        try fixture.runGpg(signer_home, &.{
            "--pinentry-mode", "loopback", "--passphrase", "",
            "--local-user",    identity,   "--output",     "test.db.sig",
            "--detach-sign",   "test.db",
        });
        try fixture.runGpg(signer_home, &.{ "--output", "public-key.gpg", "--export", identity });
        try fixture.runGpg(verifier_home, &.{ "--no-autostart", "--import", "public-key.gpg" });
        try fixture.runGpg(signer_home, &.{"--check-trustdb"});
        return fixture;
    }

    fn runGpg(self: SignatureFixture, homedir: []const u8, extra: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(std.testing.allocator);
        try argv.appendSlice(std.testing.allocator, &.{
            "gpg", "--no-options", "--homedir", homedir, "--batch", "--yes",
        });
        try argv.appendSlice(std.testing.allocator, extra);
        try runCommand(argv.items, .{ .dir = self.temporary.dir });
    }

    fn fingerprint(self: SignatureFixture, signer: []const u8) ![]const u8 {
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{
                "gpg",
                "--no-options",
                "--homedir",
                self.signer_home,
                "--batch",
                "--with-colons",
                "--list-keys",
                "--",
                signer,
            },
            .stdout_limit = .limited(65536),
            .stderr_limit = .limited(65536),
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "fpr:")) continue;
            var fields = std.mem.splitScalar(u8, line, ':');
            var index: usize = 0;
            while (fields.next()) |field| : (index += 1)
                if (index == 9) {
                    return std.testing.allocator.dupe(u8, field);
                };
        }
        return error.MissingFingerprint;
    }

    fn dataPath(self: SignatureFixture, name: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.path, name });
    }

    fn sign(
        self: SignatureFixture,
        name: []const u8,
        signer: []const u8,
        extra: []const []const u8,
    ) !void {
        const signature = try std.fmt.allocPrint(std.testing.allocator, "{s}.sig", .{name});
        defer std.testing.allocator.free(signature);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(std.testing.allocator);
        try args.appendSlice(
            std.testing.allocator,
            &.{
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--local-user",
                signer,
            },
        );
        try args.appendSlice(std.testing.allocator, extra);
        try args.appendSlice(std.testing.allocator, &.{ "--output", signature, "--detach-sign", name });
        try self.runGpg(self.signer_home, args.items);
        try self.runGpg(self.signer_home, &.{"--check-trustdb"});
    }

    fn stopAgents(self: SignatureFixture) !void {
        var failure: ?anyerror = null;
        for ([_][]const u8{ self.signer_home, self.verifier_home, self.unknown_home }) |homedir| {
            runCommand(&.{ "gpgconf", "--homedir", homedir, "--kill", "all" }, .inherit) catch |err| {
                failure = err;
            };
        }
        if (failure) |err| return err;
    }

    fn deinit(self: *SignatureFixture) !void {
        defer self.arena.deinit();
        const stopped = self.stopAgents();
        // Attempt file cleanup even if stopping an agent failed, and report errors.
        try cleanupTemporary(&self.temporary);
        try stopped;
    }
};

// Short, private homes avoid Unix socket path limits in deeply nested checkouts.
// Atomic creation rejects collisions; cleanup removes only the directory we created.
const TemporaryHome = struct {
    dir: std.Io.Dir,
    parent_dir: std.Io.Dir,
    sub_path: [25]u8,

    fn init() !TemporaryHome {
        var random: [12]u8 = undefined;
        std.testing.io.random(&random);
        var name: [25]u8 = undefined;
        @memcpy(name[0..9], "rlpm-gpg-");
        _ = std.base64.url_safe.Encoder.encode(name[9..], &random);
        var parent = try std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{});
        errdefer parent.close(std.testing.io);
        try parent.createDir(std.testing.io, &name, .fromMode(0o700));
        errdefer parent.deleteTree(std.testing.io, &name) catch {};
        const dir = try parent.openDir(std.testing.io, &name, .{});
        return .{
            .dir = dir,
            .parent_dir = parent,
            .sub_path = name,
        };
    }
};

fn cleanupTemporary(temporary: *TemporaryHome) !void {
    temporary.dir.close(std.testing.io);
    defer temporary.parent_dir.close(std.testing.io);
    try temporary.parent_dir.deleteTree(std.testing.io, &temporary.sub_path);
}

fn runCommand(argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("fixture command {s} failed ({any}):\n{s}\n{s}\n", .{
        argv[0], result.term, result.stdout, result.stderr,
    });
    return error.GpgFixtureCommandFailed;
}

test "signature: validateSignature accepts a real detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects tampered database contents" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    var tampered = SignatureFixture.contents.*;
    tampered[0] ^= 1;
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test.db", .data = &tampered });
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects a missing detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    try fixture.temporary.dir.deleteFile(std.testing.io, "test.db.sig");
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects a corrupted detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    const signature = try fixture.temporary.dir.readFileAlloc(
        std.testing.io,
        "test.db.sig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(signature);
    try std.testing.expect(signature.len > 0);
    signature[signature.len - 1] ^= 1;
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test.db.sig", .data = signature });
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "signature: validateSignature rejects an unknown signing key" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path, .{});
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.unknown_home));
}

test "real GPG separates full and unknown trust and parses binary issuers" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const path = try fixture.dataPath("test.db");
    defer std.testing.allocator.free(path);
    var snapshot = try rlpm.ImmutableFile.copy(std.testing.io, path);
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    const strict: rlpm.Verification.Options = .{ .requirement = .required };
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            .{ .gpg_directory = fixture.verifier_home },
            &snapshot,
            path,
            strict,
            &report,
        ),
    );
    try std.testing.expect(report.?.signatures[0].cryptographically_valid);
    try std.testing.expectEqualStrings("Shelly Signature Tests", report.?.signatures[0].user_name.?);
    try std.testing.expectEqualStrings("signature-tests@example.invalid", report.?.signatures[0].email.?);
    try std.testing.expect(report.?.signatures[0].key_created.? > 0);
    try std.testing.expectEqual(255, report.?.signatures[0].key_length.?);
    try std.testing.expectEqual(.unknown, report.?.signatures[0].trust);
    var permissive = strict;
    permissive.trust.allow_unknown = true;
    try std.testing.expect(
        (try rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            .{ .gpg_directory = fixture.verifier_home },
            &snapshot,
            path,
            permissive,
            &report,
        )).pgp,
    );
    try std.testing.expect(
        (try rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            .{ .gpg_directory = fixture.signer_home },
            &snapshot,
            path,
            strict,
            &report,
        )).pgp,
    );
    try std.testing.expectEqual(.full, report.?.signatures[0].trust);
    const bytes = (try rlpm.OpenPgp.readDetached(std.testing.allocator, std.testing.io, path)).?;
    defer std.testing.allocator.free(bytes);
    var issuers = try rlpm.OpenPgp.extractIssuers(std.testing.allocator, bytes);
    defer issuers.deinit();
    const fpr = try fixture.fingerprint(SignatureFixture.identity);
    defer std.testing.allocator.free(fpr);
    try std.testing.expectEqualStrings(fpr, issuers.fingerprints[0]);
    try std.testing.expectEqualStrings(fpr[fpr.len - 16 ..], issuers.key_ids[0]);
}

test "real GPG requires all signatures and rejects a tampered payload" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const second = "Second Signer <second@example.invalid>";
    try fixture.runGpg(
        fixture.signer_home,
        &.{
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--quick-generate-key",
            second,
            "ed25519",
            "sign",
            "0",
        },
    );
    try fixture.sign("test.db", SignatureFixture.identity, &.{ "--local-user", second });
    const path = try fixture.dataPath("test.db");
    defer std.testing.allocator.free(path);
    var snapshot = try rlpm.ImmutableFile.copy(std.testing.io, path);
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    try std.testing.expect(
        (try rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            .{ .gpg_directory = fixture.signer_home },
            &snapshot,
            path,
            .{ .requirement = .required },
            &report,
        )).pgp,
    );
    try std.testing.expectEqual(2, report.?.signatures.len);
    try std.testing.expectError(
        error.KeyImportDeclined,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            .{ .gpg_directory = fixture.verifier_home },
            &snapshot,
            path,
            .{
                .requirement = .optional,
                .trust = .{ .allow_unknown = true },
            },
            &report,
        ),
    );
    try std.testing.expectEqual(2, report.?.signatures.len);
    var tampered = try rlpm.ImmutableFile.fromBytes("tampered");
    defer tampered.deinit();
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            .{ .gpg_directory = fixture.signer_home },
            &tampered,
            path,
            .{ .requirement = .optional },
            &report,
        ),
    );
    try std.testing.expectEqual(2, report.?.signatures.len);
}

const ImportAnswer = struct {
    owner: ?*rlpm.Owner = null,
    accept: bool = false,
    cancel: bool = false,
    questions: usize = 0,

    fn callback(context: ?*anyopaque, question: *rlpm.Callbacks.Question) void {
        const self: *ImportAnswer = @ptrCast(@alignCast(context.?));
        std.debug.assert(question.* == .import_key);
        self.questions += 1;
        question.import_key.import = self.accept;
        if (self.owner) |owner| {
            std.testing.expectError(error.CallbackReentry, owner.unregisterSyncDatabases()) catch unreachable;
            if (self.cancel) owner.requestCancellation();
        }
    }
};

test "real Owner imports only after consent, honors cancellation and retains verified package bytes" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    var archive = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver = 1-1\narch = any\n" },
        .{ .path = ".CHANGELOG", .contents = "signed changelog" },
    }, .none);
    defer archive.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        archive.path,
        std.testing.allocator,
        .limited(65536),
    );
    defer std.testing.allocator.free(bytes);
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "demo.pkg.tar", .data = bytes });
    try fixture.sign("demo.pkg.tar", SignatureFixture.identity, &.{});
    const path = try fixture.dataPath("demo.pkg.tar");
    defer std.testing.allocator.free(path);
    const keypath = try fixture.dataPath("public-key.gpg");
    defer std.testing.allocator.free(keypath);
    try fixture.runGpg(
        fixture.signer_home,
        &.{
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--quick-generate-key",
            "Unrelated <unrelated@example.invalid>",
            "ed25519",
            "sign",
            "0",
        },
    );
    try fixture.runGpg(fixture.signer_home, &.{ "--output", "bundle.gpg", "--export" });
    const bundle = try fixture.dataPath("bundle.gpg");
    defer std.testing.allocator.free(bundle);
    var answer: ImportAnswer = .{};
    var owner = try rlpm.Owner.init(std.testing.io, std.testing.allocator, .{
        .root = fixture.path,
        .database_path = fixture.path,
        .gpg_directory = fixture.unknown_home,
        .local_file_signature_policy = .{ .package_trust = .{ .allow_unknown = true } },
        .key_acquisition = .{
            .key_files = &.{keypath},
            .allow_keyserver = false,
            .allow_wkd = false,
        },
        .callbacks = .{ .question_context = &answer, .question = ImportAnswer.callback },
    }, &.{});
    defer owner.deinit() catch unreachable;
    answer.owner = &owner;
    try std.testing.expectError(
        error.KeyImportDeclined,
        owner.loadPackage(
            std.testing.io,
            path,
            .local_file,
            .{},
        ),
    );
    answer.accept = true;
    var options = owner.options();
    options.key_acquisition.key_files = &.{bundle};
    try owner.setOptions(std.testing.io, options);
    try std.testing.expectError(
        error.InvalidKeySource,
        owner.loadPackage(
            std.testing.io,
            path,
            .local_file,
            .{},
        ),
    );
    options = owner.options();
    options.key_acquisition.key_files = &.{keypath};
    try owner.setOptions(std.testing.io, options);
    answer.cancel = true;
    try std.testing.expectError(error.Cancelled, owner.loadPackage(std.testing.io, path, .local_file, .{}));
    try owner.resetCancellation();
    answer.cancel = false;
    var package = owner.loadPackage(std.testing.io, path, .local_file, .{}) catch |err| {
        if (owner.last_verification) |report|
            for (report.key_operations.items) |operation|
                std.debug.print(
                    "GPG key operation ({any}): {s}\n",
                    .{
                        operation.termination,
                        operation.diagnostics,
                    },
                );
        return err;
    };
    defer package.deinit();
    try std.testing.expectEqual(4, answer.questions);
    try std.testing.expect(package.validation.pgp and !package.validation.none);
    var cached = try owner.loadPackage(std.testing.io, path, .local_file, .{});
    defer cached.deinit();
    try std.testing.expect(cached.validation.pgp);
    try std.testing.expectEqual(4, answer.questions);
    try fixture.temporary.dir.writeFile(
        std.testing.io,
        .{
            .sub_path = "demo.pkg.tar",
            .data = "replaced after verification",
        },
    );
    var changelog = (try package.openMember(std.testing.allocator, .changelog)).?;
    defer changelog.deinit();
    const text = try changelog.readAll(std.testing.allocator, 1024);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("signed changelog", text);
    try std.testing.expectError(
        error.InvalidSignature,
        owner.loadPackage(
            std.testing.io,
            path,
            .local_file,
            .{},
        ),
    );
}

test "real GPG marginal web-of-trust requires the marginal allowance" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const certifier = "Certifier <certifier@example.invalid>";
    const subject = "Subject <subject@example.invalid>";
    for ([_][]const u8{ certifier, subject }) |identity|
        try fixture.runGpg(
            fixture.signer_home,
            &.{
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--quick-generate-key",
                identity,
                "ed25519",
                "default",
                "0",
            },
        );
    const root_fpr = try fixture.fingerprint(SignatureFixture.identity);
    defer std.testing.allocator.free(root_fpr);
    const cert_fpr = try fixture.fingerprint(certifier);
    defer std.testing.allocator.free(cert_fpr);
    const sub_fpr = try fixture.fingerprint(subject);
    defer std.testing.allocator.free(sub_fpr);
    try fixture.runGpg(
        fixture.signer_home,
        &.{
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--local-user",
            root_fpr,
            "--quick-sign-key",
            cert_fpr,
        },
    );
    try fixture.runGpg(
        fixture.signer_home,
        &.{
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--local-user",
            cert_fpr,
            "--quick-sign-key",
            sub_fpr,
        },
    );
    try fixture.runGpg(fixture.signer_home, &.{ "--output", "all-keys.gpg", "--export" });
    try fixture.runGpg(fixture.verifier_home, &.{ "--import", "all-keys.gpg" });
    const trust = try std.fmt.allocPrint(std.testing.allocator, "{s}:6:\n{s}:4:\n", .{ root_fpr, cert_fpr });
    defer std.testing.allocator.free(trust);
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "ownertrust", .data = trust });
    try fixture.runGpg(fixture.verifier_home, &.{ "--import-ownertrust", "ownertrust" });
    try fixture.runGpg(fixture.verifier_home, &.{"--check-trustdb"});
    try fixture.sign("test.db", subject, &.{});
    const path = try fixture.dataPath("test.db");
    defer std.testing.allocator.free(path);
    var snapshot = try rlpm.ImmutableFile.copy(std.testing.io, path);
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    const context: rlpm.Verification.Context = .{ .gpg_directory = fixture.verifier_home };
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            .{
                .requirement = .required,
                .trust = .{ .allow_unknown = true },
            },
            &report,
        ),
    );
    try std.testing.expectEqual(.marginal, report.?.signatures[0].trust);
    try std.testing.expect(
        (try rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            .{
                .requirement = .required,
                .trust = .{ .allow_marginal = true },
            },
            &report,
        )).pgp,
    );
}

test "real GPG distinguishes expired signatures from refreshable expired keys" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const past = "20250101T000000";
    const expired = "Expired <expired@example.invalid>";
    try fixture.runGpg(
        fixture.signer_home,
        &.{
            "--faked-system-time",
            past,
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--quick-generate-key",
            expired,
            "ed25519",
            "sign",
            "1d",
        },
    );
    try fixture.sign("test.db", expired, &.{ "--faked-system-time", past });
    const path = try fixture.dataPath("test.db");
    defer std.testing.allocator.free(path);
    var snapshot = try rlpm.ImmutableFile.copy(std.testing.io, path);
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    const context: rlpm.Verification.Context = .{ .gpg_directory = fixture.signer_home };
    var options: rlpm.Verification.Options = .{
        .requirement = .required,
        .trust = .{ .allow_unknown = true },
    };
    try std.testing.expect(
        (try rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            options,
            &report,
        )).pgp,
    );
    try std.testing.expectEqual(.key_expired, report.?.signatures[0].status);
    options.refresh_expired_keys = true;
    try std.testing.expectError(
        error.KeyImportDeclined,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            options,
            &report,
        ),
    );
    const old = "Old <old@example.invalid>";
    try fixture.runGpg(
        fixture.signer_home,
        &.{
            "--faked-system-time",
            past,
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--quick-generate-key",
            old,
            "ed25519",
            "sign",
            "0",
        },
    );
    try fixture.sign("test.db", old, &.{ "--faked-system-time", past, "--default-sig-expire", "1d" });
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            options,
            &report,
        ),
    );
    try std.testing.expectEqual(.signature_expired, report.?.signatures[0].status);
}

test "real GPG disabled and revoked keys fail even with permissive trust" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const fpr = try fixture.fingerprint(SignatureFixture.identity);
    defer std.testing.allocator.free(fpr);
    const path = try fixture.dataPath("test.db");
    defer std.testing.allocator.free(path);
    var snapshot = try rlpm.ImmutableFile.copy(std.testing.io, path);
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    const context: rlpm.Verification.Context = .{ .gpg_directory = fixture.signer_home };
    const options: rlpm.Verification.Options = .{
        .requirement = .optional,
        .trust = .{
            .allow_unknown = true,
            .allow_marginal = true,
        },
    };
    try fixture.runGpg(fixture.signer_home, &.{ "--edit-key", fpr, "disable", "quit" });
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            options,
            &report,
        ),
    );
    try std.testing.expectEqual(.key_disabled, report.?.signatures[0].status);
    try fixture.runGpg(fixture.signer_home, &.{ "--edit-key", fpr, "enable", "quit" });
    const revoke_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "signer/openpgp-revocs.d/{s}.rev",
        .{fpr},
    );
    defer std.testing.allocator.free(revoke_path);
    const revoke = try fixture.temporary.dir.readFileAlloc(
        std.testing.io,
        revoke_path,
        std.testing.allocator,
        .limited(65536),
    );
    defer std.testing.allocator.free(revoke);
    const begin = std.mem.indexOf(u8, revoke, ":-----BEGIN PGP PUBLIC KEY BLOCK-----").?;
    try fixture.temporary.dir.writeFile(
        std.testing.io,
        .{
            .sub_path = "revoke.asc",
            .data = revoke[begin + 1 ..],
        },
    );
    try fixture.runGpg(fixture.signer_home, &.{ "--import", "revoke.asc" });
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            std.testing.allocator,
            std.testing.io,
            context,
            &snapshot,
            path,
            options,
            &report,
        ),
    );
    try std.testing.expectEqual(.key_revoked, report.?.signatures[0].status);
}

test "real signed database is authenticated before publication and failed reload retains cache" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    var archive = try Archive.init(
        &.{
            .{
                .path = "demo-1-1/desc",
                .contents = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        archive.path,
        std.testing.allocator,
        .limited(65536),
    );
    defer std.testing.allocator.free(bytes);
    try fixture.temporary.dir.createDirPath(std.testing.io, "sync");
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "sync/core.db", .data = bytes });
    try fixture.sign("sync/core.db", SignatureFixture.identity, &.{});
    var owner = try rlpm.Owner.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .root = fixture.path,
            .database_path = fixture.path,
            .gpg_directory = fixture.signer_home,
            .default_signature_policy = .{},
        },
        &.{.{ .database_name = "core" }},
    );
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("core").?;
    const package = (try owner.queryPackage(std.testing.io, db, "demo")).?;
    try std.testing.expectEqual(.full, (try owner.database(db)).last_verification.?.signatures[0].trust);
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "sync/core.db", .data = "tampered" });
    try std.testing.expectError(error.InvalidSignature, owner.reloadDatabase(std.testing.io, db));
    try std.testing.expectEqualStrings("demo", (try owner.package(package)).name);
    try std.testing.expectEqual(.invalid, (try owner.database(db)).last_verification.?.signatures[0].status);
}

test "signed downloads acquire unknown keys only with consent and revalidate cache" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const io = std.testing.io;
    const a = std.testing.allocator;
    try fixture.temporary.dir.createDirPath(io, "cache");
    const cache = try fixture.dataPath("cache");
    defer a.free(cache);
    const key = try fixture.dataPath("public-key.gpg");
    defer a.free(key);
    const url = try std.fmt.allocPrint(a, "file://{s}/test.db", .{fixture.path});
    defer a.free(url);
    var answer: ImportAnswer = .{};
    var owner = try rlpm.Owner.init(io, a, .{
        .root = fixture.path,
        .database_path = fixture.path,
        .cache_directories = &.{cache},
        .gpg_directory = fixture.unknown_home,
        .remote_file_signature_policy = .{ .package_trust = .{ .allow_unknown = true } },
        .key_acquisition = .{
            .key_files = &.{key},
            .allow_keyserver = false,
            .allow_wkd = false,
        },
        .callbacks = .{ .question = ImportAnswer.callback, .question_context = &answer },
    }, &.{});
    defer owner.deinit() catch unreachable;
    answer.owner = &owner;
    try std.testing.expectError(error.KeyImportDeclined, owner.fetchPackage(io, url));
    try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "cache/test.db", .{}));
    answer.accept = true;
    var file = try owner.fetchPackage(io, url);
    defer file.deinit();
    try std.testing.expect(file.validation.pgp);
    var cached = try owner.fetchPackage(io, url);
    defer cached.deinit();
    try std.testing.expect(cached.cached and cached.validation.pgp);
    try owner.setCallbacks(.{});
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "cache/test.db", .data = "tampered" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "test.db", .data = "tampered too" });
    try std.testing.expectError(error.InvalidSignature, owner.fetchPackage(io, url));
    const pinned = try std.Io.Dir.cwd().readFileAlloc(io, file.snapshot.path(), a, .limited(1000));
    defer a.free(pinned);
    try std.testing.expectEqualStrings(SignatureFixture.contents, pinned);
}

test "preflight retains remote signature policy and revalidates before execution" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var archive = try Archive.init(&.{
        .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver = 1-1\narch = any\n" },
        .{ .path = "payload", .contents = "signed payload" },
    }, .none);
    defer archive.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive.path, a, .limited(65536));
    defer a.free(bytes);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "demo.pkg.tar", .data = bytes });
    try fixture.sign("demo.pkg.tar", SignatureFixture.identity, &.{});
    const path = try fixture.dataPath("demo.pkg.tar");
    defer a.free(path);
    try fixture.temporary.dir.createDirPath(io, "installed-root");
    const root = try fixture.dataPath("installed-root");
    defer a.free(root);
    var owner = try rlpm.Owner.init(io, a, .{
        .root = root,
        .database_path = fixture.path,
        .gpg_directory = fixture.signer_home,
        .local_file_signature_policy = .{ .package = .disabled },
        .remote_file_signature_policy = .{ .package = .required },
    }, &.{});
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    var package: ?rlpm.Package = try owner.loadPackage(io, path, .remote_file, .{});
    defer if (package) |*pkg| pkg.deinit();
    try tx.takeArchive(&package);
    try tx.prepare();
    try tx.preflight();
    try std.testing.expect(tx.manifest().?.archives.items[0].package.validation.pgp);
    try tx.revalidatePreflight();
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "demo.pkg.tar.sig",
            .data = "corrupted detached signature",
        },
    );
    try std.testing.expectError(error.InvalidSignature, tx.revalidatePreflight());
    try std.testing.expectEqual(.failed, tx.result().state);
    try std.testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.access(
            io,
            "installed-root/payload",
            .{},
        ),
    );
}

test "signed refresh publishes a matched pair and preserves it after bad signatures" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch unreachable;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var archive = try Archive.init(
        &.{
            .{
                .path = "demo-1-1/desc",
                .contents = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    const source = try fixture.dataPath("core.db");
    defer a.free(source);
    try std.Io.Dir.cwd().copyFile(archive.path, .cwd(), source, io, .{});
    try fixture.sign("core.db", SignatureFixture.identity, &.{});
    const server = try std.fmt.allocPrint(a, "file://{s}", .{fixture.path});
    defer a.free(server);
    var owner = try rlpm.Owner.init(
        io,
        a,
        .{
            .root = fixture.path,
            .database_path = fixture.path,
            .gpg_directory = fixture.signer_home,
            .default_signature_policy = .{},
        },
        &.{
            .{
                .database_name = "core",
                .servers = &.{server},
            },
        },
    );
    defer owner.deinit() catch unreachable;
    var refresh = try owner.refreshDatabases(io, true);
    defer refresh.deinit();
    try refresh.check();
    try owner.reloadDatabase(io, owner.findDatabase("core").?);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "core.db.sig", .data = "invalid signature" });
    var rejected = try owner.refreshDatabases(io, true);
    defer rejected.deinit();
    try std.testing.expectEqual(.failed, rejected.databases[0].outcome);
    try owner.reloadDatabase(io, owner.findDatabase("core").?);
    try std.testing.expect((try owner.findPackage(owner.findDatabase("core").?, "demo")) != null);
}
