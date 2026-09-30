const std = @import("std");

pub const Algorithm = enum { md5, sha256 };

fn Hash(comptime algorithm: Algorithm) type {
    return switch (algorithm) {
        .md5 => std.crypto.hash.Md5,
        .sha256 => std.crypto.hash.sha2.Sha256,
    };
}

pub fn bytes(comptime algorithm: Algorithm, data: []const u8) [Hash(algorithm).digest_length * 2]u8 {
    var digest: [Hash(algorithm).digest_length]u8 = undefined;
    Hash(algorithm).hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Lowercase hexadecimal, as alpm_compute_md5sum/alpm_compute_sha256sum.
pub fn file(comptime algorithm: Algorithm, io: std.Io, path: []const u8) ![Hash(algorithm).digest_length * 2]u8 {
    const input = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer input.close(io);
    var hash = Hash(algorithm).init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    var digest: [Hash(algorithm).digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn check(
    comptime algorithm: Algorithm,
    io: std.Io,
    path: []const u8,
    expected: []const u8,
) !void {
    const actual = try file(algorithm, io, path);
    if (!std.mem.eql(u8, &actual, expected)) return error.ChecksumMismatch;
}
