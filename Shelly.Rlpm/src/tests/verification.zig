//! Signature verification consumer tests: no host keyring, subprocess or network access.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;
const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const key_id = "89ABCDEF01234567";
const valid = "[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG " ++ key_id ++ " Alice%20Example\n[GNUPG:] VALIDSIG " ++
    fingerprint ++
    " 2026-01-01 1767225600 0 4 0 22 8 00 " ++
    fingerprint ++
    "\n";
const trusted = valid ++ "[GNUPG:] TRUST_FULLY 0 pgp\n";
const unknown = "[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG " ++ key_id ++ " 22 8 00 1767225600 9 " ++ fingerprint ++
    "\n[GNUPG:] NO_PUBKEY " ++
    key_id ++
    "\n";
const bad = "[GNUPG:] NEWSIG\n[GNUPG:] BADSIG " ++ key_id ++ " Alice\n";

test "status matrix separates crypto, expiration, revocation, disabled keys and trust" {
    const statuses = [_]struct {
        name: []const u8,
        status: rlpm.SignatureResult.Status,
        eligible: bool,
    }{
        .{
            .name = "GOODSIG",
            .status = .valid,
            .eligible = true,
        },
        .{
            .name = "EXPKEYSIG",
            .status = .key_expired,
            .eligible = true,
        },
        .{
            .name = "EXPSIG",
            .status = .signature_expired,
            .eligible = false,
        },
        .{
            .name = "REVKEYSIG",
            .status = .key_revoked,
            .eligible = false,
        },
        .{
            .name = "BADSIG",
            .status = .invalid,
            .eligible = false,
        },
    };
    const trusts = [_]struct {
        name: []const u8,
        trust: rlpm.SignatureResult.Trust,
    }{
        .{ .name = "TRUST_FULLY", .trust = .full },
        .{ .name = "TRUST_ULTIMATE", .trust = .full },
        .{ .name = "TRUST_MARGINAL", .trust = .marginal },
        .{ .name = "TRUST_UNDEFINED", .trust = .unknown },
        .{ .name = "TRUST_NEVER", .trust = .never },
    };
    for (statuses) |status|
        for (trusts) |trust| {
            const text = try std.fmt.allocPrint(
                allocator,
                "[GNUPG:] NEWSIG\n[GNUPG:] {s} " ++ key_id ++ " Alice%20Example\n[GNUPG:] VALIDSIG " ++ fingerprint ++
                    " 2026-01-01 1767225600 0 4 0 22 8 00 " ++
                    fingerprint ++
                    "\n[GNUPG:] {s} 0 pgp\n",
                .{ status.name, trust.name },
            );
            defer allocator.free(text);
            var report = try rlpm.SignatureResult.parse(allocator, text, "diagnostic", .{ .exited = 0 });
            defer report.deinit();
            try std.testing.expectEqual(status.status, report.signatures[0].status);
            try std.testing.expectEqual(trust.trust, report.signatures[0].trust);
            try std.testing.expectEqualStrings("Alice Example", report.signatures[0].user_id.?);
            try std.testing.expectEqualStrings(fingerprint, report.signatures[0].primary_fingerprint.?);
            for ([_]bool{ false, true }) |marginal|
                for ([_]bool{ false, true }) |unknown_trust| {
                    const policy: rlpm.SignaturePolicy.Trust = .{
                        .allow_marginal = marginal,
                        .allow_unknown = unknown_trust,
                    };
                    const allowed = status.eligible and switch (trust.trust) {
                        .full => true,
                        .marginal => marginal,
                        .unknown => unknown_trust,
                        .never => false,
                    };
                    if (allowed)
                        try report.check(policy)
                    else
                        try std.testing.expectError(
                            error.InvalidSignature,
                            report.check(policy),
                        );
                };
            report.signatures[0].status = .key_disabled;
            try std.testing.expectError(
                error.InvalidSignature,
                report.check(
                    .{
                        .allow_marginal = true,
                        .allow_unknown = true,
                    },
                ),
            );
        };
}
test "multiple signatures and unsuccessful GPG statuses are retained" {
    var report = try rlpm.SignatureResult.parse(
        allocator,
        trusted ++ unknown ++ bad,
        "bad and unknown",
        .{ .exited = 2 },
    );
    defer report.deinit();
    try std.testing.expectEqual(3, report.signatures.len);
    try std.testing.expectEqual(.key_unknown, report.signatures[1].status);
    try std.testing.expectEqual(9, report.signatures[1].error_code.?);
    try std.testing.expectEqualStrings(fingerprint, report.signatures[1].fingerprint.?);
    try std.testing.expect(!report.process_failure);
    try std.testing.expectError(error.InvalidSignature, report.check(.{ .allow_unknown = true }));
    var signal = try rlpm.SignatureResult.parse(allocator, trusted, "killed", .{ .signal = .KILL });
    defer signal.deinit();
    try std.testing.expectError(error.GpgFailed, signal.check(.{}));
    var failed = try rlpm.SignatureResult.parse(allocator, trusted, "read failed", .{ .exited = 2 });
    defer failed.deinit();
    try std.testing.expectError(error.GpgFailed, failed.check(.{}));
}
test "incomplete or malformed statuses cannot authorize a signature" {
    for ([_][]const u8{
        "",
        "[GNUPG:] GOODSIG " ++ key_id ++ " Alice\n[GNUPG:] TRUST_FULLY 0\n",
        trusted ++ "[GNUPG:] NEWSIG\n",
        trusted ++ "[GNUPG:] GOODSIG " ++ key_id ++ " Alice\n",
        "[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG - Alice\n",
        "[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG " ++ key_id ++ " invalid%QZ\n",
        trusted ++ "[GNUPG:] NODATA 1\n",
    }) |text| {
        var report = try rlpm.SignatureResult.parse(allocator, text, "", .{ .exited = 0 });
        defer report.deinit();
        try std.testing.expectError(error.InvalidSignature, report.check(.{}));
    }
    var failure = try rlpm.SignatureResult.parse(
        allocator,
        trusted ++ "[GNUPG:] FAILURE verify 123\n",
        "",
        .{ .exited = 2 },
    );
    defer failure.deinit();
    try std.testing.expectError(error.GpgFailed, failure.check(.{}));
}

fn parserAllocations(gpa: std.mem.Allocator) !void {
    var report = try rlpm.SignatureResult.parse(gpa, trusted ++ unknown ++ bad, "stderr", .{ .exited = 2 });
    defer report.deinit();
    try std.testing.expectEqual(3, report.signatures.len);
}
test "structured status results release all allocations on failure" {
    try std.testing.checkAllAllocationFailures(allocator, parserAllocations, .{});
}
test "checksum helpers stream files and prefer SHA256 over MD5" {
    try std.testing.expectEqualStrings(
        "900150983cd24fb0d6963f7d28e17f72",
        &rlpm.Checksum.bytes(.md5, "abc"),
    );
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &rlpm.Checksum.bytes(.sha256, "abc"),
    );
    var snapshot = try rlpm.ImmutableFile.fromBytes("abc");
    defer snapshot.deinit();
    try std.testing.expectEqualStrings(
        &rlpm.Checksum.bytes(.md5, "abc"),
        &try rlpm.Checksum.file(.md5, io, snapshot.path()),
    );
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    const performed = try rlpm.Verification.check(
        allocator,
        io,
        .{},
        &snapshot,
        "absent",
        .{
            .requirement = .disabled,
            .md5 = "wrong",
            .sha256 = &rlpm.Checksum.bytes(.sha256, "abc"),
        },
        &report,
    );
    try std.testing.expect(performed.sha256 and !performed.md5 and !performed.none and !performed.pgp);
    try std.testing.expectError(
        error.ChecksumMismatch,
        rlpm.Verification.check(
            allocator,
            io,
            .{},
            &snapshot,
            "absent",
            .{
                .requirement = .disabled,
                .sha256 = "wrong",
            },
            &report,
        ),
    );
}
const packet = "\xc2\x2c\x04\x00\x16\x08\x00\x17\x16\x21\x04" ++
    "\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67" ++
    "\x00\x0a\x09\x10\x89\xab\xcd\xef\x01\x23\x45\x67\x00\x00\x01";
test "bounded packet parsing exposes issuer IDs and fingerprints" {
    var issuers = try rlpm.OpenPgp.extractIssuers(allocator, packet);
    defer issuers.deinit();
    try std.testing.expectEqualStrings(key_id, issuers.key_ids[0]);
    try std.testing.expectEqualStrings(fingerprint, issuers.fingerprints[0]);
    for (0..packet.len) |n| {
        if (rlpm.OpenPgp.extractIssuers(allocator, packet[0..n])) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try std.testing.expectError(
        error.UnsupportedSignaturePacket,
        rlpm.OpenPgp.extractIssuers(
            allocator,
            "\xc2\xe0",
        ),
    );
    const encoded = std.base64.standard.Encoder;
    var buffer: [encoded.calcSize(packet.len)]u8 = undefined;
    const decoded = try rlpm.OpenPgp.decode(allocator, encoded.encode(&buffer, packet));
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, packet, decoded);
    try std.testing.expectError(error.InvalidCharacter, rlpm.OpenPgp.decode(allocator, "AA A"));
}

const Fake = struct {
    var status: []const u8 = trusted;
    var exit: u8 = 0;
    var disabled: bool = false;
    var failure: ?anyerror = null;
    var imports: usize = 0;

    fn run(gpa: std.mem.Allocator, _: std.Io, home: []const u8, args: []const []const u8) !std.process.RunResult {
        if (failure) |err| return err;
        try std.testing.expectEqualStrings("/explicit/keyring", home);
        var output = status;
        var code = exit;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--list-keys")) {
                output = if (disabled)
                    "pub:-:255:22:" ++ key_id ++ ":0:0:::::scD:\n"
                else
                    "pub:-:255:22:" ++ key_id ++ ":0:0:::::sc:\n";
                code = 0;
            }
            if (std.mem.eql(u8, arg, "--recv-keys")) {
                imports += 1;
                output = "";
                status = trusted;
                exit = 0;
                code = 0;
            }
        }
        const stdout = try gpa.dupe(u8, output);
        errdefer gpa.free(stdout);
        return .{
            .stdout = stdout,
            .stderr = try gpa.dupe(u8, "test diagnostic"),
            .term = .{ .exited = code },
        };
    }

    fn ask(_: ?*anyopaque, question: *rlpm.Callbacks.Question) !void {
        try std.testing.expectEqualStrings(fingerprint, question.import_key.key.fingerprint);
        question.import_key.import = true;
    }

    fn wrong(_: ?*anyopaque, question: *rlpm.Callbacks.Question) !void {
        question.* = .{ .remove_packages = .{ .packages = &.{} } };
    }

    fn reset() void {
        status = trusted;
        exit = 0;
        disabled = false;
        failure = null;
        imports = 0;
    }

    fn context() rlpm.Verification.Context {
        return .{ .gpg_directory = "/explicit/keyring", .runner = run };
    }
};

test "optional signatures verify when present; disabled skips GPG and missing required fails" {
    Fake.reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "data", .data = "abc" });
    const path = try temporary.dir.realPathFileAlloc(io, "data", allocator);
    defer allocator.free(path);
    var snapshot = try rlpm.ImmutableFile.copy(io, path);
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    try std.testing.expectError(
        error.SignatureMissing,
        rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            path,
            .{ .requirement = .required },
            &report,
        ),
    );
    try std.testing.expect(
        (try rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            path,
            .{ .requirement = .optional },
            &report,
        )).none,
    );
    try temporary.dir.writeFile(io, .{ .sub_path = "data.sig", .data = "present" });
    Fake.status = bad;
    Fake.exit = 1;
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            path,
            .{ .requirement = .optional },
            &report,
        ),
    );
    try std.testing.expectEqual(1, report.?.signatures.len);
    Fake.failure = error.FileNotFound;
    try std.testing.expect(
        (try rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            path,
            .{ .requirement = .disabled },
            &report,
        )).none,
    );
    try std.testing.expectError(
        error.FileNotFound,
        rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            path,
            .{ .requirement = .required },
            &report,
        ),
    );
    Fake.failure = null;
    Fake.exit = 0;
    Fake.status = trusted;
    Fake.disabled = true;
    try std.testing.expectError(
        error.InvalidSignature,
        rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            path,
            .{ .requirement = .required },
            &report,
        ),
    );
    try std.testing.expectEqual(.key_disabled, report.?.signatures[0].status);
}
test "embedded signatures skip digests only when enabled and imports require consent plus reverification" {
    Fake.reset();
    var snapshot = try rlpm.ImmutableFile.fromBytes("abc");
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    const options: rlpm.Verification.Options = .{
        .requirement = .required,
        .base64_signature = "AQ==",
        .sha256 = "wrong",
    };
    const performed = try rlpm.Verification.check(
        allocator,
        io,
        Fake.context(),
        &snapshot,
        "absent",
        options,
        &report,
    );
    try std.testing.expect(performed.pgp and !performed.sha256);
    var disabled = options;
    disabled.requirement = .disabled;
    try std.testing.expectError(
        error.ChecksumMismatch,
        rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            "absent",
            disabled,
            &report,
        ),
    );
    Fake.status = unknown;
    Fake.exit = 2;
    try std.testing.expectError(
        error.KeyImportDeclined,
        rlpm.Verification.check(
            allocator,
            io,
            Fake.context(),
            &snapshot,
            "absent",
            options,
            &report,
        ),
    );
    try std.testing.expectEqual(0, Fake.imports);
    var context = Fake.context();
    context.question = Fake.ask;
    try std.testing.expect(
        (try rlpm.Verification.check(
            allocator,
            io,
            context,
            &snapshot,
            "absent",
            options,
            &report,
        )).pgp,
    );
    try std.testing.expectEqual(1, Fake.imports);
    try std.testing.expectEqual(.valid, report.?.signatures[0].status);
}
const pkginfo = "pkgname = demo\npkgver = 1-1\npkgdesc = test\narch = any\n";
test "Owner policies and retained package bytes survive replacement of a cached path" {
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = pkginfo },
            .{
                .path = ".CHANGELOG",
                .contents = "verified changelog",
            },
            .{
                .path = "usr/file",
                .contents = "payload",
            },
        },
        .none,
    );
    defer archive.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var owner = try rlpm.Owner.init(
        io,
        allocator,
        .{
            .root = root,
            .database_path = root,
            .default_signature_policy = .{},
            .local_file_signature_policy = null,
            .remote_file_signature_policy = .{ .package = .disabled },
        },
        &.{},
    );
    defer owner.deinit() catch unreachable;
    try std.testing.expectError(
        error.SignatureMissing,
        owner.loadPackage(io, archive.path, .local_file, .{}),
    );
    try std.testing.expectEqual(.integrity, owner.diagnostic().?.category);
    var package = try owner.loadPackage(io, archive.path, .remote_file, .{ .mode = .full });
    defer package.deinit();
    try std.testing.expect(package.validation.none);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = archive.path, .data = "replaced" });
    var member = (try package.openMember(allocator, .changelog)).?;
    defer member.deinit();
    const bytes = try member.readAll(allocator, 1024);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("verified changelog", bytes);
    try std.testing.expectError(error.ArchiveFailed, owner.loadPackage(io, archive.path, .remote_file, .{}));
}
test "rejected database reload preserves the prior generation and last signature results" {
    Fake.reset();
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
    var database = try rlpm.Database.initSync(
        allocator,
        .{ .database_name = "core" },
        archive.path,
        .{ .database = .optional },
    );
    defer database.deinit();
    try database.reloadWithVerification(io, Fake.context());
    const generation = database.generation;
    const sigpath = try std.fmt.allocPrint(allocator, "{s}.sig", .{archive.path});
    defer allocator.free(sigpath);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sigpath, .data = "present" });
    Fake.status = bad;
    Fake.exit = 1;
    try std.testing.expectError(error.InvalidSignature, database.reloadWithVerification(io, Fake.context()));
    try std.testing.expectEqual(generation, database.generation);
    try std.testing.expect(database.status.isUsable());
    try std.testing.expectEqualStrings("demo", database.packages.packages.items[0].name);
    try std.testing.expectEqual(.invalid, database.last_verification.?.signatures[0].status);
}

const ReferenceRunner = struct {
    var row: std.json.Value = undefined;

    fn run(gpa: std.mem.Allocator, _: std.Io, _: []const u8, args: []const []const u8) !std.process.RunResult {
        var listing = false;
        for (args) |arg|
            if (std.mem.eql(u8, arg, "--list-keys")) {
                listing = true;
            };
        const stdout = try gpa.dupe(u8, row.object.get(if (listing) "keys" else "status").?.string);
        errdefer gpa.free(stdout);
        return .{
            .stdout = stdout,
            .stderr = try gpa.dupe(u8, ""),
            .term = .{
                .exited = if (listing)
                    0
                else
                    @intCast(row.object.get("exit").?.integer),
            },
        };
    }
};
test "independent pinned libalpm file-policy matrix, checksums and issuers" {
    const fixture = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        @embedFile("fixtures/signature-reference.json"),
        .{},
    );
    defer fixture.deinit();
    const checksums = fixture.value.object.get("checksums").?.object;
    const bytes = try rlpm.OpenPgp.decode(allocator, checksums.get("data_base64").?.string);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(checksums.get("md5").?.string, &rlpm.Checksum.bytes(.md5, bytes));
    try std.testing.expectEqualStrings(
        checksums.get("sha256").?.string,
        &rlpm.Checksum.bytes(.sha256, bytes),
    );
    const issuer = fixture.value.object.get("issuer").?.object;
    const signature = try rlpm.OpenPgp.decode(allocator, issuer.get("signature_base64").?.string);
    defer allocator.free(signature);
    var issuers = try rlpm.OpenPgp.extractIssuers(allocator, signature);
    defer issuers.deinit();
    const fpr = issuer.get("fingerprint").?.string;
    try std.testing.expectEqualStrings(fpr, issuers.fingerprints[0]);
    try std.testing.expectEqualStrings(fpr[fpr.len - 16 ..], issuers.key_ids[0]);
    var snapshot = try rlpm.ImmutableFile.fromBytes(bytes);
    defer snapshot.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const cases = fixture.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(12, cases.len);
    for (cases) |row| {
        ReferenceRunner.row = row;
        for (row.object.get("policies").?.array.items) |policy| {
            const values = policy.object;
            const requirement = std.meta.stringToEnum(
                rlpm.SignaturePolicy.Verification,
                values.get("requirement").?.string,
            ).?;
            var report: ?rlpm.SignatureResult = null;
            defer rlpm.Verification.clearReport(&report);
            const actual = rlpm.Verification.check(allocator, io, .{ .runner = ReferenceRunner.run }, &snapshot, path, .{
                .requirement = requirement,
                .trust = .{
                    .allow_marginal = values.get("allow_marginal").?.bool,
                    .allow_unknown = values.get("allow_unknown").?.bool,
                },
                .base64_signature = if (row.object.get("present").?.bool) "AQ==" else null,
                .refresh_expired_keys = true,
            }, &report);
            const success = if (actual) |_| true else |_| false;
            if (success != values.get("success").?.bool)
                std.debug.print(
                    "reference case {s}, {s}, marginal={}, unknown={}\n",
                    .{
                        row.object.get("name").?.string,
                        @tagName(requirement),
                        values.get("allow_marginal").?.bool,
                        values.get("allow_unknown").?.bool,
                    },
                );
            try std.testing.expectEqual(values.get("success").?.bool, success);
            if (success) {
                const performed = try actual;
                const flags: u8 = @as(u8, @intFromBool(performed.none)) | (@as(u8, @intFromBool(performed.pgp)) << 3);
                try std.testing.expectEqual(values.get("validation").?.integer, flags);
            }
        }
    }
}

fn verifyAllocations(gpa: std.mem.Allocator) !void {
    Fake.reset();
    Fake.status = unknown;
    Fake.exit = 2;
    var snapshot = try rlpm.ImmutableFile.fromBytes("abc");
    defer snapshot.deinit();
    var report: ?rlpm.SignatureResult = null;
    defer rlpm.Verification.clearReport(&report);
    var context = Fake.context();
    context.question = Fake.ask;
    const validation = try rlpm.Verification.check(
        gpa,
        io,
        context,
        &snapshot,
        "unused",
        .{
            .requirement = .required,
            .base64_signature = "AQ==",
        },
        &report,
    );
    try std.testing.expect(validation.pgp);
}
test "verification and reimport release every allocation on failure" {
    try std.testing.checkAllAllocationFailures(allocator, verifyAllocations, .{});
}

test "repository package validation uses effective policy and actual cached bytes" {
    var archive = try Archive.init(&.{.{ .path = ".PKGINFO", .contents = pkginfo }}, .none);
    defer archive.deinit();
    const digest = try rlpm.Checksum.file(.sha256, io, archive.path);
    const desc = try std.fmt.allocPrint(
        allocator,
        "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%MD5SUM%\nwrong\n\n%SHA256SUM%\n{s}\n\n",
        .{digest},
    );
    defer allocator.free(desc);
    var repository = try Archive.init(&.{.{ .path = "demo-1-1/desc", .contents = desc }}, .none);
    defer repository.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "sync");
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const database_bytes = try std.Io.Dir.cwd().readFileAlloc(io, repository.path, allocator, .limited(65536));
    defer allocator.free(database_bytes);
    try temporary.dir.writeFile(io, .{ .sub_path = "sync/core.db", .data = database_bytes });
    var owner = try rlpm.Owner.init(
        io,
        allocator,
        .{
            .root = root,
            .database_path = root,
            .default_signature_policy = .{},
        },
        &.{
            .{
                .database_name = "core",
                .signature_policy = .{
                    .database = .disabled,
                    .package = .disabled,
                },
            },
        },
    );
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("core").?;
    const reference = (try owner.queryPackage(io, db, "demo")).?;
    const metadata = try owner.package(reference);
    try std.testing.expect(metadata.validation.none);
    try std.testing.expectError(error.ChecksumMismatch, metadata.checkMd5sum(io, archive.path));
    try std.testing.expect(try metadata.getSignature(allocator, io, archive.path) == null);
    var package = try owner.loadPackage(io, archive.path, .{ .repository = reference }, .{});
    defer package.deinit();
    try std.testing.expect(
        package.validation.sha256 and !package.validation.md5 and !package.validation.pgp,
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = archive.path, .data = "cache changed" });
    try std.testing.expectError(
        error.ChecksumMismatch,
        owner.loadPackage(
            io,
            archive.path,
            .{ .repository = reference },
            .{},
        ),
    );
    try owner.invalidateDatabase(db);
    try std.testing.expectError(
        error.StalePackageReference,
        owner.loadPackage(
            io,
            archive.path,
            .{ .repository = reference },
            .{},
        ),
    );
}

test "kernel seals prohibit rewriting a verified snapshot" {
    const native = std.c;
    var snapshot = try rlpm.ImmutableFile.fromBytes("verified");
    defer snapshot.deinit();
    try std.testing.expectEqual(-1, native.pwrite(snapshot.fd, "X", 1, 0));
    try std.testing.expectEqual(@intFromEnum(native.E.PERM), native._errno().*);
    try std.testing.expectEqualStrings(
        &rlpm.Checksum.bytes(.sha256, "verified"),
        &try rlpm.Checksum.file(
            .sha256,
            io,
            snapshot.path(),
        ),
    );
}
