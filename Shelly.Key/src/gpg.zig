const std = @import("std");
const Io = std.Io;
const process = std.process;

pub const GpgError = error{
    GpgFailed,
};

/// Wrapper around the `gpg` CLI bound to a specific homedir.
///
/// Every command is invoked as
/// `gpg --homedir <homedir> --no-permission-warning <command...>`.
pub const Gpg = struct {
    io: Io,
    homedir: []const u8,

    /// Run `gpg --homedir <dir> --no-permission-warning --update-trustdb`
    pub fn updateTrustdb(self: Gpg) !void {
        try self.run(&.{"--update-trustdb"}, null, null);
    }

    /// Run `gpg --homedir <dir> --no-permission-warning -K --with-colons`
    pub fn secretKeysAvailable(self: Gpg) !bool {
        var argv: [argv_capacity][]const u8 = undefined;
        const argv_len = buildArgv(&argv, &.{ "-K", "--with-colons" }, self.homedir);

        var child = try process.spawn(self.io, .{
            .argv = argv[0..argv_len],
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(self.io);

        // Any output means a secret key exists; drain fully to avoid blocking.
        var buf: [4096]u8 = undefined;
        var available = false;
        while (true) {
            const n = child.stdout.?.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            if (n > 0) available = true;
        }
        child.stdout.?.close(self.io);
        child.stdout = null;

        try checkTerm(try child.wait(self.io));
        return available;
    }

    /// Run `gpg --homedir <dir> --no-permission-warning --gen-key --batch`
    pub fn genKey(self: Gpg, batch_input: []const u8) !void {
        try self.run(&.{ "--gen-key", "--batch" }, batch_input, null);
    }

    /// Run `gpg --homedir <dir> --no-permission-warning --batch --check-trustdb`
    pub fn checkTrustdb(self: Gpg) !void {
        try self.run(&.{ "--batch", "--check-trustdb" }, null, null);
    }

    /// Run `gpg --homedir <dir> --no-permission-warning --quiet --import <path>`.
    pub fn importKeyring(self: Gpg, path: []const u8) !void {
        try self.run(&.{ "--quiet", "--import", path }, null, null);
    }

    /// Run `gpg --homedir <dir> --no-permission-warning --import-ownertrust <path>`.
    pub fn importOwnertrust(self: Gpg, path: []const u8) !void {
        try self.run(&.{ "--import-ownertrust", path }, null, null);
    }

    /// Run `gpg --homedir <dir> --no-permission-warning --command-fd 0 --quiet --batch --lsign-key <key_id>`,
    pub fn locallySignKey(
        self: Gpg,
        allocator: std.mem.Allocator,
        env_map: *const process.Environ.Map,
        key_id: []const u8,
    ) !void {
        var sign_env = try env_map.clone(allocator);
        defer sign_env.deinit();
        // Override `LANG` to ensure consistent output.
        try sign_env.put("LANG", "C");
        try self.run(
            &.{ "--command-fd", "0", "--quiet", "--batch", "--lsign-key", key_id },
            "y\ny\n", // The `y\ny\n` is needed to suppress confirmation prompts.
            &sign_env,
        );
    }

    /// Run `gpg --with-colons --list-secret-key --quiet`.
    pub fn firstSecretKeyId(self: Gpg, allocator: std.mem.Allocator) !?[]u8 {
        const output = try self.runCapture(allocator, &.{
            "--with-colons", "--list-secret-key", "--quiet",
        });
        defer allocator.free(output);
        return parseFirstSecretKeyId(allocator, output);
    }

    /// Run `gpg --with-colons --check-signatures --quiet <key_id>`.
    pub fn keyIsLsigned(
        self: Gpg,
        allocator: std.mem.Allocator,
        secret_key_id: []const u8,
        key_id: []const u8,
    ) !bool {
        const output = try self.runCapture(allocator, &.{
            "--with-colons", "--check-signatures", "--quiet", key_id,
        });
        defer allocator.free(output);
        return parseKeyIsLsigned(output, secret_key_id);
    }

    /// Run `gpg --with-colons --list-key --quiet <key_id>`.
    pub fn keyIsRevoked(
        self: Gpg,
        allocator: std.mem.Allocator,
        key_id: []const u8,
    ) !bool {
        const output = try self.runCapture(allocator, &.{
            "--with-colons", "--list-key", "--quiet", key_id,
        });
        defer allocator.free(output);
        return parseKeyIsRevoked(output);
    }

    /// Run `gpg --command-fd 0 --no-auto-check-trustdb --quiet --batch --edit-key <key_id>`.
    pub fn disableKey(
        self: Gpg,
        allocator: std.mem.Allocator,
        env_map: *const process.Environ.Map,
        key_id: []const u8,
    ) !void {
        var disable_env = try env_map.clone(allocator);
        defer disable_env.deinit();
        // Override `LANG` to ensure consistent output.
        try disable_env.put("LANG", "C");
        try self.run(
            &.{
                "--command-fd",
                "0",
                "--no-auto-check-trustdb",
                "--quiet",
                "--batch",
                "--edit-key",
                key_id,
            },
            "disable\nquit\n", // Feed the `disable` and `quit` commands to the edit menu.
            &disable_env,
        );
    }

    fn runCapture(self: Gpg, allocator: std.mem.Allocator, extra: []const []const u8) ![]u8 {
        var argv: [argv_capacity][]const u8 = undefined;
        const argv_len = buildArgv(&argv, extra, self.homedir);

        var child = try process.spawn(self.io, .{
            .argv = argv[0..argv_len],
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(self.io);

        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            if (n > 0) {
                try list.appendSlice(allocator, buf[0..n]);
            }
        }
        child.stdout.?.close(self.io);
        child.stdout = null;

        try checkTerm(try child.wait(self.io));
        return try list.toOwnedSlice(allocator);
    }

    /// Spawn `gpg --homedir <homedir> --no-permission-warning <extra...>`.
    fn run(
        self: Gpg,
        extra: []const []const u8,
        stdin_data: ?[]const u8,
        env_map: ?*const process.Environ.Map,
    ) !void {
        var argv: [argv_capacity][]const u8 = undefined;
        const argv_len = buildArgv(&argv, extra, self.homedir);

        const stdin_kind: process.SpawnOptions.StdIo =
            if (stdin_data != null) .pipe else .inherit;

        var child = try process.spawn(self.io, .{
            .argv = argv[0..argv_len],
            .stdin = stdin_kind,
            .stdout = .inherit,
            .stderr = .inherit,
            .environ_map = env_map,
        });
        errdefer child.kill(self.io);

        if (stdin_data) |data| {
            try child.stdin.?.writeStreamingAll(self.io, data);
            child.stdin.?.close(self.io);
            child.stdin = null;
        }

        try checkTerm(try child.wait(self.io));
    }
};

/// Maximum argv capacity: `gpg --homedir <dir> --no-permission-warning`
/// (4 slots) plus room for command-specific arguments.
const argv_capacity: usize = 12;

fn buildArgv(
    argv: *[argv_capacity][]const u8,
    extra: []const []const u8,
    homedir: []const u8,
) usize {
    var n: usize = 0;
    argv[n] = "gpg";
    n += 1;
    argv[n] = "--homedir";
    n += 1;
    argv[n] = homedir;
    n += 1;
    argv[n] = "--no-permission-warning";
    n += 1;
    for (extra) |arg| {
        argv[n] = arg;
        n += 1;
    }
    return n;
}

fn checkTerm(term: process.Child.Term) GpgError!void {
    switch (term) {
        .exited => |code| if (code != 0) return error.GpgFailed,
        .signal, .stopped, .unknown => return error.GpgFailed,
    }
}

fn colonField(line: []const u8, index: usize) []const u8 {
    var i: usize = 0;
    var start: usize = 0;
    for (line, 0..) |c, pos| {
        if (c == ':') {
            if (i == index) return line[start..pos];
            i += 1;
            start = pos + 1;
        }
    }
    if (i == index) return line[start..];
    return "";
}

fn parseFirstSecretKeyId(allocator: std.mem.Allocator, output: []const u8) !?[]u8 {
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        if (!std.mem.eql(u8, colonField(line, 0), "sec")) continue;
        const key_id = colonField(line, 4);
        if (key_id.len == 0) continue;
        return try allocator.dupe(u8, key_id);
    }
    return null;
}

fn parseKeyIsLsigned(output: []const u8, secret_key_id: []const u8) bool {
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        if (!std.mem.eql(u8, colonField(line, 0), "sig")) continue;
        if (!std.mem.eql(u8, colonField(line, 1), "!")) continue;
        if (std.mem.eql(u8, colonField(line, 4), secret_key_id)) return true;
    }
    return false;
}

fn parseKeyIsRevoked(output: []const u8) bool {
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        if (!std.mem.eql(u8, colonField(line, 0), "pub")) continue;
        const flags = colonField(line, 11);
        return std.mem.indexOfScalar(u8, flags, 'D') != null;
    }
    return false;
}

const testing = std.testing;

test "buildArgv prefixes every command with the homedir boilerplate" {
    var argv: [argv_capacity][]const u8 = undefined;
    const n = buildArgv(&argv, &.{ "-K", "--with-colons" }, "/tmp/gnupg");

    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualStrings("gpg", argv[0]);
    try testing.expectEqualStrings("--homedir", argv[1]);
    try testing.expectEqualStrings("/tmp/gnupg", argv[2]);
    try testing.expectEqualStrings("--no-permission-warning", argv[3]);
    try testing.expectEqualStrings("-K", argv[4]);
    try testing.expectEqualStrings("--with-colons", argv[5]);
}

test "checkTerm accepts a zero exit code" {
    try checkTerm(.{ .exited = 0 });
}

test "checkTerm rejects a nonzero exit code" {
    try testing.expectError(error.GpgFailed, checkTerm(.{ .exited = 2 }));
}

test "checkTerm rejects signal termination" {
    try testing.expectError(
        error.GpgFailed,
        checkTerm(.{ .signal = .TERM }),
    );
}

test "checkTerm rejects stopped and unknown terminations" {
    try testing.expectError(error.GpgFailed, checkTerm(.{ .stopped = .TERM }));
    try testing.expectError(error.GpgFailed, checkTerm(.{ .unknown = 0x7f }));
}

test "colonField extracts the record type (field 0)" {
    const line = "pub:u:4096:1:ABCDEF1234567890:2020-01-01:::u:::scESC:";
    try testing.expectEqualStrings("pub", colonField(line, 0));
}

test "colonField extracts the validity (field 1)" {
    const line = "sig:!::1:ABCDEF1234567890:2020-01-01::::Test:::13x:";
    try testing.expectEqualStrings("!", colonField(line, 1));
}

test "colonField extracts the key ID (field 4)" {
    const line = "sec:u:4096:1:ABCDEF1234567890:2020-01-01:::u:::scESC:";
    try testing.expectEqualStrings("ABCDEF1234567890", colonField(line, 4));
}

test "colonField returns empty for out-of-range index" {
    const line = "pub:u:4096";
    try testing.expectEqualStrings("", colonField(line, 10));
}

test "colonField returns empty for an empty line" {
    try testing.expectEqualStrings("", colonField("", 0));
}

test "colonField handles empty fields" {
    const line = "sig:!::1:ABCDEF1234567890:";
    try testing.expectEqualStrings("", colonField(line, 2));
    try testing.expectEqualStrings("1", colonField(line, 3));
}

test "colonField handles a line without a trailing colon" {
    const line = "pub:u:4096:1:ABCDEF1234567890";
    try testing.expectEqualStrings("ABCDEF1234567890", colonField(line, 4));
}

test "parseFirstSecretKeyId returns the first sec record key ID" {
    const output =
        "sec:u:4096:1:ABCDEF1234567890:2020-01-01:::u:::scESC:\n" ++
        "uid:u::::::::Test User <test@example.com>::\n";
    const result = try parseFirstSecretKeyId(testing.allocator, output);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("ABCDEF1234567890", result.?);
}

test "parseFirstSecretKeyId skips a leading tru record" {
    const output =
        "tru:o:1:1234567890:0:3:1:0\n" ++
        "sec:u:4096:1:ABCDEF1234567890:2020-01-01:::u:::scESC:\n";
    const result = try parseFirstSecretKeyId(testing.allocator, output);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("ABCDEF1234567890", result.?);
}

test "parseFirstSecretKeyId returns null for empty output" {
    const result = try parseFirstSecretKeyId(testing.allocator, "");
    try testing.expect(result == null);
}

test "parseFirstSecretKeyId returns null when only pub records exist" {
    const output = "pub:u:4096:1:ABCDEF1234567890:2020-01-01:::u:::scESC:\n";
    const result = try parseFirstSecretKeyId(testing.allocator, output);
    try testing.expect(result == null);
}

test "parseKeyIsLsigned returns true when a matching sig record exists" {
    const output =
        "pub:u:4096:1:ABCD1111ABCD1111:2020-01-01:::u:::scESC:\n" ++
        "uid:u::::::::Test User <test@example.com>::\n" ++
        "sig:!::1:ABCDEF1234567890:2020-01-01::::Test User:::13x:\n";
    try testing.expect(parseKeyIsLsigned(output, "ABCDEF1234567890"));
}

test "parseKeyIsLsigned returns false when sig validity is not bang" {
    const output = "sig:-:1:ABCDEF1234567890:2020-01-01::::Test User:::13x:\n";
    try testing.expect(!parseKeyIsLsigned(output, "ABCDEF1234567890"));
}

test "parseKeyIsLsigned returns false when the signing key differs" {
    const output = "sig:!::1:DIFFERENTKEY12345:2020-01-01::::Test User:::13x:\n";
    try testing.expect(!parseKeyIsLsigned(output, "ABCDEF1234567890"));
}

test "parseKeyIsLsigned returns false when no sig records exist" {
    const output = "pub:u:4096:1:ABCD1111ABCD1111:2020-01-01:::u:::scESC:\n";
    try testing.expect(!parseKeyIsLsigned(output, "ABCDEF1234567890"));
}

test "parseKeyIsLsigned returns false on empty output" {
    try testing.expect(!parseKeyIsLsigned("", "ABCDEF1234567890"));
}

test "parseKeyIsRevoked returns true when the pub record flags contain D" {
    // Field 12 (index 11) holds the capability/flags column; `D` marks disabled.
    const output = "pub:d:4096:1:ABCD1111ABCD1111:2020-01-01:::d:::sDcESC:\n";
    try testing.expect(parseKeyIsRevoked(output));
}

test "parseKeyIsRevoked returns true when D appears alongside other flags" {
    const output = "pub:u:4096:1:ABCD1111ABCD1111:2020-01-01:::u:::sDc::\n";
    try testing.expect(parseKeyIsRevoked(output));
}

test "parseKeyIsRevoked returns false when the pub record has no D flag" {
    const output = "pub:u:4096:1:ABCD1111ABCD1111:2020-01-01:::u:::scESC:\n";
    try testing.expect(!parseKeyIsRevoked(output));
}

test "parseKeyIsRevoked ignores D flags in non-pub records" {
    const output =
        "pub:u:4096:1:ABCD1111ABCD1111:2020-01-01:::u:::scESC:\n" ++
        "sub:d:2048:1:DEAD2222DEAD2222:2020-01-01:::d:::e::\n";
    // The pub record is not disabled, so the key is not considered revoked.
    try testing.expect(!parseKeyIsRevoked(output));
}

test "parseKeyIsRevoked returns false when no pub record exists" {
    const output = "uid:u::::::::Test User <test@example.com>::\n";
    try testing.expect(!parseKeyIsRevoked(output));
}

test "parseKeyIsRevoked returns false on empty output" {
    try testing.expect(!parseKeyIsRevoked(""));
}

test "parseKeyIsRevoked inspects only the first pub record" {
    const output =
        "pub:u:4096:1:ABCD1111ABCD1111:2020-01-01:::u:::scESC:\n" ++
        "pub:d:4096:1:ABCD1111ABCD1111:2020-01-01:::d:::scESC:\n";
    // First pub is not disabled; we do not consider a later pub.
    try testing.expect(!parseKeyIsRevoked(output));
}
