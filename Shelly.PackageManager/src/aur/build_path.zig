//! PATH policy for native, unprivileged package builds.
const std = @import("std");

pub const baseline = "/usr/bin/core_perl:/usr/bin/vendor_perl:/usr/bin/site_perl:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin";

pub fn validateEntry(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, ":\x00") != null)
        return error.InvalidBuildPath;
}

fn accessibleDirectory(io: std.Io, path: []const u8) !void {
    if ((try std.Io.Dir.cwd().statFile(io, path, .{})).kind != .directory)
        return error.NotDir;
    try std.Io.Dir.cwd().access(io, path, .{ .execute = true });
}

/// Call only after dropping privileges. Explicit additions are required;
/// unavailable optional system directories are omitted. On failure, bad_path
/// identifies the configured entry for the caller's diagnostic.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    extra_path: []const []const u8,
    bad_path: *?[]const u8,
) ![]u8 {
    bad_path.* = null;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);
    for (extra_path) |path| {
        bad_path.* = path;
        try validateEntry(path);
        try accessibleDirectory(io, path);
        try appendUnique(allocator, &entries, path);
    }
    bad_path.* = null;
    var system = std.mem.splitScalar(u8, baseline, ':');
    while (system.next()) |path| {
        accessibleDirectory(io, path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => continue,
            else => return err,
        };
        try appendUnique(allocator, &entries, path);
    }
    if (entries.items.len == 0) return error.EmptyBuildPath;
    return std.mem.join(allocator, ":", entries.items);
}

fn appendUnique(allocator: std.mem.Allocator, entries: *std.ArrayList([]const u8), path: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const normalized = if (trimmed.len == 0) "/" else trimmed;
    for (entries.items) |entry| if (std.mem.eql(u8, entry, normalized)) return;
    try entries.append(allocator, normalized);
}

/// Enabled compiler wrappers retain their precedence over configured tools.
pub fn withWrappers(allocator: std.mem.Allocator, path: []const u8, ccache: bool, distcc: bool) ![]u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);
    if (ccache) try appendUnique(allocator, &entries, "/usr/lib/ccache/bin");
    if (distcc) try appendUnique(allocator, &entries, "/usr/lib/distcc/bin");
    var paths = std.mem.splitScalar(u8, path, ':');
    while (paths.next()) |entry| if (entry.len != 0) try appendUnique(allocator, &entries, entry);
    return std.mem.join(allocator, ":", entries.items);
}

test "native build PATH validates explicit directories and preserves precedence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const trailing = try std.fmt.allocPrint(allocator, "{s}/", .{directory});
    defer allocator.free(trailing);
    var bad: ?[]const u8 = null;
    const path = try resolve(allocator, io, &.{ directory, trailing, "/usr/bin" }, &bad);
    defer allocator.free(path);
    const prefix = try std.fmt.allocPrint(allocator, "{s}:/usr/bin:", .{directory});
    defer allocator.free(prefix);
    try std.testing.expect(std.mem.startsWith(u8, path, prefix));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, path, directory));
    try std.testing.expect(bad == null);

    try temporary.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    const file = try std.fs.path.join(allocator, &.{ directory, "file" });
    defer allocator.free(file);
    try std.testing.expectError(error.NotDir, resolve(allocator, io, &.{file}, &bad));
    try std.testing.expectEqualStrings(file, bad.?);
    const missing = try std.fs.path.join(allocator, &.{ directory, "missing" });
    defer allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, resolve(allocator, io, &.{missing}, &bad));
    try std.testing.expectEqualStrings(missing, bad.?);
}

test "native build PATH rejects inaccessible configured directories as the build user" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var directory = try temporary.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer directory.close(std.testing.io);
    try directory.setPermissions(std.testing.io, .fromMode(0o600));
    defer directory.setPermissions(std.testing.io, .fromMode(0o700)) catch {};
    var bad: ?[]const u8 = null;
    try std.testing.expectError(error.AccessDenied, resolve(std.testing.allocator, std.testing.io, &.{path}, &bad));
    try std.testing.expectEqualStrings(path, bad.?);
}

test "native build PATH keeps compiler wrappers first without duplicate components" {
    const path = try withWrappers(std.testing.allocator, "/opt/tools:/usr/lib/ccache/bin:/usr/bin:/usr/bin/", true, true);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/usr/lib/ccache/bin:/usr/lib/distcc/bin:/opt/tools:/usr/bin", path);
}
