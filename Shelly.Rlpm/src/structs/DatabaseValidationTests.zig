const std = @import("std");
const Database = @import("Database.zig");

const SignatureFixture = struct {
    temporary: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    signer_home: []const u8,
    verifier_home: []const u8,
    unknown_home: []const u8,

    const contents = "Shelly database signature fixture\n\x00\x01\x02\xff";
    const identity = "Shelly Signature Tests <signature-tests@example.invalid>";

    fn init() !SignatureFixture {
        // Missing tools are the only reason these integration tests may skip.
        for ([_][]const u8{ "gpg", "gpgconf", "gpg-agent" }) |executable| {
            runCommand(&.{ executable, "--version" }, .inherit) catch |err| switch (err) {
                error.FileNotFound => {
                    std.debug.print("integration test requires {s}\n", .{executable});
                    return error.SkipZigTest;
                },
                else => return err,
            };
        }

        var temporary = std.testing.tmpDir(.{});
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

fn cleanupTemporary(temporary: *std.testing.TmpDir) !void {
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

test "integration validateSignature accepts a real detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path);
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "integration validateSignature rejects tampered database contents" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path);
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    var tampered = SignatureFixture.contents.*;
    tampered[0] ^= 1;
    try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test.db", .data = &tampered });
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "integration validateSignature rejects a missing detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path);
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    try fixture.temporary.dir.deleteFile(std.testing.io, "test.db.sig");
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.verifier_home));
}

test "integration validateSignature rejects a corrupted detached signature" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path);
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

test "integration validateSignature rejects an unknown signing key" {
    var fixture = try SignatureFixture.init();
    defer fixture.deinit() catch |err| {
        std.debug.panic("signature fixture cleanup failed: {t}", .{err});
    };
    var database = try Database.init(std.testing.allocator, "test", fixture.path);
    defer database.deinit();

    try std.testing.expect(try database.validateSignature(std.testing.io, fixture.verifier_home));
    try std.testing.expect(!try database.validateSignature(std.testing.io, fixture.unknown_home));
}

// Simulate only GPG's process and stdout operations, without accessing a keyring.
const SignatureTestIo = struct {
    output: []const u8 = "[GNUPG:] GOODSIG test-key Test Signer\n",
    term: std.process.Child.Term = .{ .exited = 0 },
    spawn_error: ?std.process.SpawnError = null,
    read_error: ?std.Io.Operation.FileReadStreaming.Error = null,
    spawned: bool = false,
    closed: bool = false,
    waited: bool = false,
    killed: bool = false,

    const vtable: std.Io.VTable = blk: {
        var result = std.Io.failing.vtable.*;
        result.processSpawn = spawn;
        result.operate = operate;
        result.fileClose = close;
        result.childWait = wait;
        result.childKill = kill;
        break :blk result;
    };

    fn io(self: *SignatureTestIo) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    fn fromContext(context: ?*anyopaque) *SignatureTestIo {
        return @ptrCast(@alignCast(context.?));
    }

    fn spawn(context: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = fromContext(context);
        self.spawned = true;
        std.debug.assert(std.mem.eql(u8, options.argv[0], "gpg"));
        std.debug.assert(options.stdout == .pipe);
        if (self.spawn_error) |err| return err;
        return .{
            .id = std.mem.zeroes(std.process.Child.Id),
            .thread_handle = undefined,
            .stdin = null,
            .stdout = .{ .handle = std.mem.zeroes(std.Io.File.Handle), .flags = .{ .nonblocking = false } },
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    }

    fn operate(context: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self = fromContext(context);
        const read = operation.file_read_streaming;
        if (self.read_error) |err| return .{ .file_read_streaming = err };
        if (self.output.len == 0) return .{ .file_read_streaming = error.EndOfStream };
        // Deliver small chunks to exercise capture across multiple reads.
        const count = @min(read.data[0].len, self.output.len, 7);
        @memcpy(read.data[0][0..count], self.output[0..count]);
        self.output = self.output[count..];
        return .{ .file_read_streaming = count };
    }

    fn close(context: ?*anyopaque, _: []const std.Io.File) void {
        fromContext(context).closed = true;
    }

    fn wait(context: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const self = fromContext(context);
        self.waited = true;
        child.id = null;
        return self.term;
    }

    fn kill(context: ?*anyopaque, child: *std.process.Child) void {
        const self = fromContext(context);
        self.killed = true;
        if (child.stdout != null) self.closed = true;
        child.stdout = null;
        child.id = null;
    }
};

test "validateSignature accepts a successful GPG exit" {
    var database = try Database.init(std.testing.allocator, "extra", "/test/sync");
    defer database.deinit();

    var fake: SignatureTestIo = .{};
    try std.testing.expect(try database.validateSignature(fake.io(), null));
    try std.testing.expect(fake.spawned and fake.closed and fake.waited);
    try std.testing.expect(!fake.killed);
}

test "validateSignature rejects unsuccessful GPG termination" {
    var database = try Database.init(std.testing.allocator, "extra", "/test/sync");
    defer database.deinit();

    const terms: []const std.process.Child.Term = &.{
        .{ .exited = 1 },
        .{ .exited = 2 },
        .{ .signal = .TERM },
        .{ .stopped = .TERM },
        .{ .unknown = 0x7f },
    };
    for (terms) |term| {
        // Even apparently successful status text must not override failure.
        var fake: SignatureTestIo = .{ .term = term };
        try std.testing.expect(!try database.validateSignature(fake.io(), null));
        try std.testing.expect(fake.closed and fake.waited);
    }
}

test "validateSignature propagates process and read errors" {
    var database = try Database.init(std.testing.allocator, "extra", "/test/sync");
    defer database.deinit();

    var missing_gpg: SignatureTestIo = .{ .spawn_error = error.FileNotFound };
    try std.testing.expectError(error.FileNotFound, database.validateSignature(missing_gpg.io(), null));
    try std.testing.expect(missing_gpg.spawned and !missing_gpg.waited);

    var failed_read: SignatureTestIo = .{ .read_error = error.InputOutput };
    try std.testing.expectError(error.InputOutput, database.validateSignature(failed_read.io(), null));
    try std.testing.expect(failed_read.closed and failed_read.killed);
    try std.testing.expect(!failed_read.waited);
}

test "validateSignature cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            var database = try Database.init(allocator, "extra", "/test/sync");
            defer database.deinit();
            var fake: SignatureTestIo = .{};
            try std.testing.expect(try database.validateSignature(fake.io(), null));
        }
    }.check, .{});
}
