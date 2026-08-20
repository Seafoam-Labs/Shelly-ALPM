//! PKGBUILD source checksum tables and file-hash verification.

const std = @import("std");

const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const PackageBuild = pkgbuild_parser.Pkgbuild;

pub fn validateChecksumCount(source_count: usize, sums: ?[][]const u8) !void {
    if (sums) |values| if (values.len != 0 and values.len != source_count) return error.SourceChecksumCountMismatch;
}

pub const ChecksumAlgorithm = enum { sha512, sha384, sha256, sha224, sha1, md5, b2 };

pub const ChecksumSet = struct {
    algorithm: ChecksumAlgorithm,
    sums: ?[][]const u8,
};

pub fn checksumSets(package_build: *const PackageBuild) [7]ChecksumSet {
    return .{
        .{ .algorithm = .sha512, .sums = package_build.sha_512_sums },
        .{ .algorithm = .sha384, .sums = package_build.sha_384_sums },
        .{ .algorithm = .sha256, .sums = package_build.sha_256_sums },
        .{ .algorithm = .sha224, .sums = package_build.sha_224_sums },
        .{ .algorithm = .sha1, .sums = package_build.sha_1_sums },
        .{ .algorithm = .md5, .sums = package_build.md_5_sums },
        .{ .algorithm = .b2, .sums = package_build.b_2_sums },
    };
}

pub fn hasSourceChecksums(package_build: *const PackageBuild) bool {
    for (checksumSets(package_build)) |set|
        if (set.sums) |sums| if (sums.len > 0) return true;
    return false;
}

pub fn requireSkippedVcsChecksums(package_build: *const PackageBuild, index: usize) !void {
    for (checksumSets(package_build)) |set| {
        const sums = set.sums orelse continue;
        if (sums.len > 0 and !std.ascii.eqlIgnoreCase(sums[index], "SKIP"))
            return error.UnsupportedVcsChecksum;
    }
}

pub fn verifyFileHash(comptime Hash: type, io: std.Io, path: []const u8, expected: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(expected, "SKIP")) return;
    if (expected.len != Hash.digest_length * 2) return error.InvalidSourceChecksum;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var hasher = Hash.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const remaining: usize = @intCast(@min(stat.size - offset, buffer.len));
        const amount = try file.readPositionalAll(io, buffer[0..remaining], offset);
        if (amount == 0) return error.SourceReadFailed;
        hasher.update(buffer[0..amount]);
        offset += amount;
    }
    var digest: [Hash.digest_length]u8 = undefined;
    hasher.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual, expected)) return error.SourceChecksumMismatch;
}

test "validateChecksumCount accepts matching, empty, and missing tables" {
    try validateChecksumCount(2, null);
    var sums_storage = [_][]const u8{ "a", "b" };
    const sums: [][]const u8 = &sums_storage;
    try validateChecksumCount(2, sums);
    var empty_storage = [_][]const u8{};
    const empty: [][]const u8 = &empty_storage;
    try validateChecksumCount(5, empty);
    try std.testing.expectError(error.SourceChecksumCountMismatch, validateChecksumCount(3, sums));
}

test "checksum tables report presence and enforce SKIP for VCS sources" {
    var pkg = pkgbuild_parser.Pkgbuild{
        .variables = .init(std.testing.allocator),
        .local_source_contents = .init(std.testing.allocator),
    };
    defer pkg.deinit(std.testing.allocator);

    try std.testing.expect(!hasSourceChecksums(&pkg));
    try requireSkippedVcsChecksums(&pkg, 0);

    const skip = try std.testing.allocator.alloc([]const u8, 1);
    skip[0] = try std.testing.allocator.dupe(u8, "SKIP");
    pkg.sha_512_sums = skip;
    try std.testing.expect(hasSourceChecksums(&pkg));
    try requireSkippedVcsChecksums(&pkg, 0);

    std.testing.allocator.free(skip[0]);
    skip[0] = try std.testing.allocator.dupe(u8, "0123456789abcdef");
    try std.testing.expectError(error.UnsupportedVcsChecksum, requireSkippedVcsChecksums(&pkg, 0));
}

test "verifyFileHash matches sha256, honors SKIP, and rejects mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.bin", .data = "hello" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "f.bin", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello", &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try verifyFileHash(std.crypto.hash.sha2.Sha256, std.testing.io, path, &expected);
    try verifyFileHash(std.crypto.hash.sha2.Sha256, std.testing.io, path, "SKIP");
    try std.testing.expectError(error.SourceChecksumMismatch, verifyFileHash(std.crypto.hash.sha2.Sha256, std.testing.io, path, "0" ** 64));
    try std.testing.expectError(error.InvalidSourceChecksum, verifyFileHash(std.crypto.hash.sha2.Sha256, std.testing.io, path, "abc"));
}
