//! Controlled PKGBUILD edits shared by native and isolated builds.
const std = @import("std");
const metadata = @import("metadata.zig");

/// Like makepkg, replace column-zero pkgver/pkgrel assignments and retain
/// trailing comments. Quote the version as shell data, even when it contains
/// metacharacters permitted by the pkgver character rules.
pub fn render(allocator: std.mem.Allocator, content: []const u8, version: []const u8) ![]u8 {
    try metadata.validatePkgver(version);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var lines = std.mem.splitScalar(u8, content, '\n');
    var found_version = false;
    var found_release = false;
    while (lines.next()) |line| {
        const is_version = std.mem.startsWith(u8, line, "pkgver=");
        const is_release = std.mem.startsWith(u8, line, "pkgrel=");
        if (is_version or is_release) {
            found_version = found_version or is_version;
            found_release = found_release or is_release;
            try output.writer.writeAll(if (is_version) "pkgver=" else "pkgrel=");
            if (is_version) {
                try output.writer.writeByte('\'');
                for (version) |byte| {
                    if (byte == '\'') try output.writer.writeAll("'\\''") else try output.writer.writeByte(byte);
                }
                try output.writer.writeByte('\'');
            } else try output.writer.writeByte('1');
            const suffix = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            try output.writer.writeAll(line[suffix..]);
        } else try output.writer.writeAll(line);
        if (lines.peek() != null) try output.writer.writeByte('\n');
    }
    if (!found_version or !found_release) return error.UnsupportedPkgverAssignment;
    return output.toOwnedSlice();
}

/// Returns false for an unwritable PKGBUILD (makepkg warns and keeps the old
/// version). Write through the verified inode to preserve ownership and mode.
pub fn write(allocator: std.mem.Allocator, io: std.Io, path: []const u8, original: []const u8, updated: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive }) catch |err| switch (err) {
        error.AccessDenied, error.ReadOnlyFileSystem => return false,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidPkgbuildPath;
    if (stat.permissions.toMode() & 0o222 == 0) return false;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const current = try reader.interface.allocRemaining(allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, original)) return error.ReviewedPkgbuildChanged;
    try file.writePositionalAll(io, updated, 0);
    try file.setLength(io, updated.len);
    try file.sync(io);
    return true;
}

/// Treat the guest file as untrusted data: accept only our exact two-field
/// transformation, never copy arbitrary guest PKGBUILD content onto the host.
pub fn extractChange(allocator: std.mem.Allocator, original: []const u8, updated: []const u8) !?[]u8 {
    if (std.mem.eql(u8, original, updated)) return null;
    // Decode only the literal emitted by render. No shell evaluation or full
    // PKGBUILD parsing is needed to validate the guest's two-field edit.
    var value: std.Io.Writer.Allocating = .init(allocator);
    defer value.deinit();
    var lines = std.mem.splitScalar(u8, updated, '\n');
    const literal = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "pkgver='")) break line[8..];
    } else return error.ReviewedPkgbuildChanged;
    var index: usize = 0;
    while (index < literal.len) {
        if (std.mem.startsWith(u8, literal[index..], "'\\''")) {
            try value.writer.writeByte('\'');
            index += 4;
        } else if (literal[index] == '\'') {
            break;
        } else {
            try value.writer.writeByte(literal[index]);
            index += 1;
        }
    } else return error.ReviewedPkgbuildChanged;
    const version = value.written();
    const expected = try render(allocator, original, version);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, updated)) return error.ReviewedPkgbuildChanged;
    return try allocator.dupe(u8, version);
}

test "PackageBuilder pkgver writeback accepts only controlled guest edits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const original = "# retained\npkgname=demo\npkgver='1' # old\npkgrel=7\narch=('any')\npackage() { :; }\n";
    try std.testing.expectEqual(@as(?[]u8, null), try extractChange(allocator, original, original));
    const updated = try render(allocator, original, "r2.gabc");
    defer allocator.free(updated);
    const version = (try extractChange(allocator, original, updated)).?;
    defer allocator.free(version);
    try std.testing.expectEqualStrings("r2.gabc", version);
    try std.testing.expect(std.mem.indexOf(u8, updated, "pkgver='r2.gabc' # old\npkgrel=1\n") != null);
    const tampered = try std.mem.concat(allocator, u8, &.{ updated, "\n# unrelated guest edit\n" });
    defer allocator.free(tampered);
    try std.testing.expectError(error.ReviewedPkgbuildChanged, extractChange(allocator, original, tampered));
    try std.testing.expectError(error.InvalidPackageVersion, render(allocator, original, "invalid-version"));
    for ([_][]const u8{ "r2+tag", "2'quoted", "2$(id)", "2;false" }) |unusual| {
        const quoted = try render(allocator, original, unusual);
        defer allocator.free(quoted);
        const decoded = (try extractChange(allocator, original, quoted)).?;
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings(unusual, decoded);
    }

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = original });
    try temporary.dir.setFilePermissions(io, "PKGBUILD", .fromMode(0o640), .{});
    const path = try temporary.dir.realPathFileAlloc(io, "PKGBUILD", allocator);
    defer allocator.free(path);
    try std.testing.expect(try write(allocator, io, path, original, updated));
    try std.testing.expectEqual(@as(u32, 0o640), (try temporary.dir.statFile(io, "PKGBUILD", .{})).permissions.toMode() & 0o777);
    try std.testing.expectError(error.ReviewedPkgbuildChanged, write(allocator, io, path, original, updated));
    const after = try temporary.dir.readFileAlloc(io, "PKGBUILD", allocator, .unlimited);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(updated, after);
}
