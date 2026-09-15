const std = @import("std");
const runtime = @import("../runtime/context.zig");

/// GnuPG probes its agent socket even for public-key imports with no-autostart.
/// Without /run/user (as in isolated builds), that socket lives under HOME;
/// std.testing.tmpDir's cache-relative path can exceed the Unix socket limit.
pub const PgpTmpDir = struct {
    dir: std.Io.Dir,
    path: []u8,

    pub fn init() !PgpTmpDir {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var random: [16]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const path = try std.fmt.allocPrint(allocator, "/tmp/shelly-pgp-{s}", .{suffix});
        errdefer allocator.free(path);
        // Exclusive creation avoids reusing another process's keyring.
        try std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700));
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        const dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        return .{ .dir = dir, .path = path };
    }

    pub fn cleanup(self: *PgpTmpDir) void {
        self.dir.close(std.testing.io);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch {};
        std.testing.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const TestContext = struct {
    arena: std.heap.ArenaAllocator = undefined,
    stdout: std.Io.Writer.Allocating = undefined,
    stderr: std.Io.Writer.Allocating = undefined,
    context: runtime.RuntimeContext = undefined,

    pub fn init(self: *TestContext) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
        self.stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
        self.context = .{
            .allocator = self.arena.allocator(),
            .io = std.testing.io,
            .stdout = &self.stdout.writer,
            .stderr = &self.stderr.writer,
        };
    }

    pub fn deinit(self: *TestContext) void {
        self.stderr.deinit();
        self.stdout.deinit();
        self.arena.deinit();
    }
};
