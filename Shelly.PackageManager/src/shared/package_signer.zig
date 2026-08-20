const std = @import("std");

/// Reusable OpenPGP signer that creates detached binary signatures for built
/// package archives. It never evaluates a shell command and only interprets
/// GnuPG's exit status. Callers remain responsible for atomic publication of
/// the signed artifact pair.
pub const Signer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    gpg_path: []const u8 = "/usr/bin/gpg",
    gnupg_home: ?[]const u8 = null,
    timeout_seconds: u32 = 60,

    pub fn signDetached(
        self: Signer,
        payload_path: []const u8,
        signature_path: []const u8,
        key: ?[]const u8,
    ) !void {
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(self.allocator);
        try arguments.appendSlice(self.allocator, &.{ self.gpg_path, "--quiet", "--batch", "--no-tty" });
        if (self.gnupg_home) |home|
            try arguments.appendSlice(self.allocator, &.{ "--homedir", home });
        if (key) |selected|
            try arguments.appendSlice(self.allocator, &.{ "--local-user", selected });
        try arguments.appendSlice(self.allocator, &.{ "--detach-sign", "--output", signature_path, payload_path });

        var environment = try self.environ.createMap(self.allocator);
        defer environment.deinit();
        if (self.gnupg_home) |home| try environment.put("GNUPGHOME", home);
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = arguments.items,
            .environ_map = &environment,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(self.timeout_seconds) } },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        if (exit_code != 0) {
            std.log.warn(
                "package signing failed for {s} (gpg exit {d}): {s}",
                .{ payload_path, exit_code, result.stderr },
            );
            return error.PackageSigningFailed;
        }
    }
};

test "package signer rejects missing keys without creating a signature" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/home/invoker");
    const environ: std.process.Environ = .{
        .block = try map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer environ.block.deinit(std.testing.allocator);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "payload", .data = "unsigned content\n" });
    const payload_path = try std.fs.path.join(std.testing.allocator, &.{ root, "payload" });
    defer std.testing.allocator.free(payload_path);
    const signature_path = try std.fs.path.join(std.testing.allocator, &.{ root, "payload.sig" });
    defer std.testing.allocator.free(signature_path);
    const gnupg_home = try std.fs.path.join(std.testing.allocator, &.{ root, "gnupg-home" });
    defer std.testing.allocator.free(gnupg_home);

    const signer = Signer{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
        .gnupg_home = gnupg_home,
    };
    try std.testing.expectError(
        error.PackageSigningFailed,
        signer.signDetached(payload_path, signature_path, "missing-key-id"),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, signature_path, .{}),
    );
}
