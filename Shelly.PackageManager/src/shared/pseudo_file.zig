//! Reads pseudo-files, such as procfs entries, without trusting their `stat`
//! size. Shared between the restart checks and the CLI process tracking so a
//! size-based read never re-enters a procfs path.

const std = @import("std");
const builtin = @import("builtin");

/// Reads a file to EOF through the descriptor instead of sizing the read from
/// `stat`. procfs reports `st_size == 0` for files such as `osrelease`, `maps`,
/// `comm`, `stat` and `environ`, so size-based helpers like `Dir.readFileAlloc`
/// return an empty buffer without issuing a single `read` call (Zig 0.17.0,
/// ziglang/zig#31946). A streaming reader reads until EOF instead. Content
/// beyond `limit` fails with `error.StreamTooLong`, matching the previous
/// `Shelly.Cli.Zig` pseudo-file helper.
pub fn readAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
}

test "procfs files are read in full" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const maps = try readAlloc(testing.io, testing.allocator, "/proc/self/maps", .limited(16 * 1024 * 1024));
    defer testing.allocator.free(maps);
    try testing.expect(maps.len > 0);
    const kernel = try readAlloc(testing.io, testing.allocator, "/proc/sys/kernel/osrelease", .limited(4096));
    defer testing.allocator.free(kernel);
    try testing.expect(std.mem.trim(u8, kernel, " \t\r\n").len > 0);
}

test "regular files are read in full and limits are enforced" {
    const testing = std.testing;
    const anchor: u8 = 0;
    // Parallel test binaries reuse similar ASLR addresses, so include the pid
    // to keep concurrent runs of this suite from deleting each other's file.
    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/shelly-pseudo-file-test-{x}-{d}",
        .{ @intFromPtr(&anchor), std.c.getpid() },
    );
    defer testing.allocator.free(path);
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const payload = "shelly pseudo file payload\n";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = payload });
    const contents = try readAlloc(testing.io, testing.allocator, path, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(payload, contents);
    try testing.expectError(error.StreamTooLong, readAlloc(testing.io, testing.allocator, path, .limited(4)));
}
