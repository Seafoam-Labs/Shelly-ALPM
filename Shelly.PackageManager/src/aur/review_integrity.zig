const std = @import("std");
const pkgbuild_parser = @import("../pkgbuild/pkgbuild_parser.zig");

const max_file_size = 32 * 1024 * 1024;

fn hashReviewField(
    hash: *std.crypto.hash.sha2.Sha256,
    name: []const u8,
    content: []const u8,
) void {
    const name_length: u64 = @intCast(name.len);
    const content_length: u64 = @intCast(content.len);
    hash.update(std.mem.asBytes(&name_length));
    hash.update(name);
    hash.update(std.mem.asBytes(&content_length));
    hash.update(content);
}

pub fn requireReviewInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    info: *const pkgbuild_parser.Pkgbuild,
) !void {
    if (info.install_file) |install_file|
        try requireReviewedFile(allocator, io, cache_path, install_file);
    if (info.local_source_files) |files| for (files) |file_name| {
        try requireReviewedFile(allocator, io, cache_path, file_name);
        if (!info.local_source_contents.contains(file_name)) return error.MissingPkgbuildSourceFile;
    };
}

pub fn requireReviewedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    file_name: []const u8,
) !void {
    if (file_name.len == 0 or std.fs.path.isAbsolute(file_name))
        return error.UnsafePkgbuildSourcePath;
    const path = try std.fs.path.join(allocator, &.{ cache_path, file_name });
    defer allocator.free(path);
    const status = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPkgbuildSourceFile,
        else => return err,
    };
    if (status.kind != .file) return error.UnsafePkgbuildSourcePath;
    const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, cache_path, allocator);
    defer allocator.free(canonical_root);
    const canonical_file = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(canonical_file);
    if (!pathIsInside(canonical_root, canonical_file)) return error.UnsafePkgbuildSourcePath;
}

pub fn pathIsInside(root: []const u8, candidate: []const u8) bool {
    return candidate.len > root.len and
        std.mem.startsWith(u8, candidate, root) and
        std.fs.path.isSep(candidate[root.len]);
}

pub fn reviewDigest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    pkgbuild_content: []const u8,
    info: *const pkgbuild_parser.Pkgbuild,
) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashReviewField(&hash, "PKGBUILD", pkgbuild_content);
    if (info.install_file) |install_file|
        try hashReviewedFile(allocator, io, &hash, cache_path, install_file);
    if (info.local_source_files) |files| for (files) |file_name|
        try hashReviewedFile(allocator, io, &hash, cache_path, file_name);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashReviewedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    hash: *std.crypto.hash.sha2.Sha256,
    cache_path: []const u8,
    file_name: []const u8,
) !void {
    try requireReviewedFile(allocator, io, cache_path, file_name);
    const path = try std.fs.path.join(allocator, &.{ cache_path, file_name });
    defer allocator.free(path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
    defer allocator.free(content);
    hashReviewField(hash, file_name, content);
    const status = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    var encoded_mode: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded_mode, status.permissions.toMode() & 0o777, .little);
    hashReviewField(hash, "permissions", &encoded_mode);
}
