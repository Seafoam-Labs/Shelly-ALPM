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

    /// `gpg --homedir <dir> --no-permission-warning --update-trustdb`
    pub fn updateTrustdb(self: Gpg) !void {
        try self.run(&.{"--update-trustdb"}, null);
    }

    /// `gpg --homedir <dir> --no-permission-warning -K --with-colons`
    pub fn listSecretKeys(self: Gpg) !void {
        try self.run(&.{ "-K", "--with-colons" }, null);
    }

    /// `gpg --homedir <dir> --no-permission-warning --gen-key --batch`
    ///
    /// `batch_input` is written to the child's stdin (the unattended key
    /// generation parameters gpg reads in batch mode).
    pub fn genKey(self: Gpg, batch_input: []const u8) !void {
        try self.run(&.{ "--gen-key", "--batch" }, batch_input);
    }

    /// `gpg --homedir <dir> --no-permission-warning --batch --check-trustdb`
    pub fn checkTrustdb(self: Gpg) !void {
        try self.run(&.{ "--batch", "--check-trustdb" }, null);
    }

    /// Spawns `gpg --homedir <homedir> --no-permission-warning <extra...>`.
    ///
    /// When `stdin_data` is non-null, a pipe is created for stdin, the data is
    /// written and the write end is closed so the child observes EOF. Otherwise
    /// stdin is inherited from the parent process. stdout and stderr are always
    /// inherited.
    fn run(self: Gpg, extra: []const []const u8, stdin_data: ?[]const u8) !void {
        var argv: [8][]const u8 = undefined;
        var n: usize = 0;
        argv[n] = "gpg";
        n += 1;
        argv[n] = "--homedir";
        n += 1;
        argv[n] = self.homedir;
        n += 1;
        argv[n] = "--no-permission-warning";
        n += 1;
        for (extra) |arg| {
            argv[n] = arg;
            n += 1;
        }

        const stdin_kind: process.SpawnOptions.StdIo =
            if (stdin_data != null) .pipe else .inherit;

        var child = try process.spawn(self.io, .{
            .argv = argv[0..n],
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

        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.GpgFailed,
            .signal, .stopped, .unknown => return error.GpgFailed,
        }
    }
};
