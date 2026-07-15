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
        try self.run(&.{"--update-trustdb"}, null);
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
    ///
    /// `batch_input` is written to the stdin.
    pub fn genKey(self: Gpg, batch_input: []const u8) !void {
        try self.run(&.{ "--gen-key", "--batch" }, batch_input);
    }

    /// Run `gpg --homedir <dir> --no-permission-warning --batch --check-trustdb`
    pub fn checkTrustdb(self: Gpg) !void {
        try self.run(&.{ "--batch", "--check-trustdb" }, null);
    }

    /// Spawn `gpg --homedir <homedir> --no-permission-warning <extra...>`.
    fn run(self: Gpg, extra: []const []const u8, stdin_data: ?[]const u8) !void {
        var argv: [argv_capacity][]const u8 = undefined;
        const argv_len = buildArgv(&argv, extra, self.homedir);

        const stdin_kind: process.SpawnOptions.StdIo =
            if (stdin_data != null) .pipe else .inherit;

        var child = try process.spawn(self.io, .{
            .argv = argv[0..argv_len],
            .stdin = stdin_kind,
            .stdout = .inherit,
            .stderr = .inherit,
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
const argv_capacity: usize = 8;

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
