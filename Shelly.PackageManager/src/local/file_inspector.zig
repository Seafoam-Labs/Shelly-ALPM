const std = @import("std");
const archive = @import("archive");

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn isArchPackage(self: Inspector, file_path: []const u8) !bool {
        if (!isSupportedArchive(file_path)) return false;
        var reader = try archive.Reader.init(self.allocator, file_path);
        defer reader.deinit();

        while (try reader.next()) |entry| {
            const base = std.fs.path.basename(entry.path);
            if (std.ascii.eqlIgnoreCase(base, ".PKGINFO") or
                std.ascii.eqlIgnoreCase(base, "PKGINFO")) return true;
        }
        return false;
    }

    pub fn isBinariesPackage(self: Inspector, file_path: []const u8) !bool {
        if (!isSupportedArchive(file_path)) return false;
        var reader = try archive.Reader.init(self.allocator, file_path);
        defer reader.deinit();

        while (try reader.next()) |entry| {
            if (entry.kind != .regular_file) continue;
            var magic: [4]u8 = undefined;
            const amount = try reader.readPrefix(&magic);
            if (isElfBytes(magic[0..amount])) return true;
        }
        return false;
    }

    pub fn isElfFile(self: Inspector, file_path: []const u8) !bool {
        var file = try std.Io.Dir.cwd().openFile(self.io, file_path, .{});
        defer file.close(self.io);
        var magic: [4]u8 = undefined;
        const amount = try file.readPositionalAll(self.io, &magic, 0);
        return isElfBytes(magic[0..amount]);
    }
};

pub fn isSupportedArchive(file_path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(file_path, ".tar.gz") or
        std.ascii.endsWithIgnoreCase(file_path, ".tgz") or
        std.ascii.endsWithIgnoreCase(file_path, ".tar.zst") or
        std.ascii.endsWithIgnoreCase(file_path, ".tzst") or
        std.ascii.endsWithIgnoreCase(file_path, ".tar");
}

pub fn isIcon(path_or_extension: []const u8) bool {
    const extension = if (std.mem.lastIndexOfScalar(u8, path_or_extension, '.')) |dot|
        path_or_extension[dot..]
    else
        path_or_extension;
    return std.ascii.eqlIgnoreCase(extension, ".png") or
        std.ascii.eqlIgnoreCase(extension, ".svg");
}

pub fn isElfBytes(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF");
}

test "inspector recognizes ELF bytes icons and supported archives" {
    try std.testing.expect(isElfBytes("\x7fELFpayload"));
    try std.testing.expect(!isElfBytes("text"));
    try std.testing.expect(isIcon("logo.SVG"));
    try std.testing.expect(isIcon("/tmp/logo.png"));
    try std.testing.expect(!isIcon("logo.jpg"));
    try std.testing.expect(isSupportedArchive("demo.tar.zst"));
    try std.testing.expect(isSupportedArchive("demo.TAR.GZ"));
    try std.testing.expect(!isSupportedArchive("demo.zip"));
}

test "inspector distinguishes Arch packages and local binary archives" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const arch_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/arch.pkg.tar.zst",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(arch_path);
    try archive.writeFixture(testing.allocator, arch_path, .zstd, &.{
        .{ .path = ".PKGINFO", .contents = "pkgname = demo\n" },
    });

    const binary_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/binary.tar.gz",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(binary_path);
    try archive.writeFixture(testing.allocator, binary_path, .gzip, &.{
        .{ .path = "demo", .contents = "\x7fELFpayload", .permissions = 0o755 },
    });

    const inspector: Inspector = .{ .allocator = testing.allocator, .io = testing.io };
    try testing.expect(try inspector.isArchPackage(arch_path));
    try testing.expect(!(try inspector.isBinariesPackage(arch_path)));
    try testing.expect(!(try inspector.isArchPackage(binary_path)));
    try testing.expect(try inspector.isBinariesPackage(binary_path));
}
