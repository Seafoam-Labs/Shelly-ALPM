//! Publish a PKGBUILD and generated SRCINFO after both have been prepared.
const std = @import("std");

const Snapshot = struct {
    path: [:0]u8,
    requested_path: []u8,
    content: ?[]u8,
    permissions: std.Io.File.Permissions,
    inode: ?std.Io.File.INode = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, required: bool) !Snapshot {
        const requested_path = try allocator.dupe(u8, path);
        errdefer allocator.free(requested_path);
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
            error.FileNotFound => if (!required) try allocator.dupeZ(u8, path) else return err,
            else => return err,
        };
        errdefer allocator.free(canonical);
        const stat = std.Io.Dir.cwd().statFile(io, canonical, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (!required) return .{ .path = canonical, .requested_path = requested_path, .content = null, .permissions = .default_file } else return err,
            else => return err,
        };
        if (stat.kind != .file) return error.InvalidPkgbuildPath;
        if (stat.permissions.toMode() & 0o222 == 0) return error.PkgbuildNotWritable;
        return .{
            .path = canonical,
            .requested_path = requested_path,
            .content = try std.Io.Dir.cwd().readFileAlloc(io, canonical, allocator, .limited(32 * 1024 * 1024)),
            .permissions = stat.permissions,
            .inode = stat.inode,
        };
    }

    fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.requested_path);
        if (self.content) |value| allocator.free(value);
    }

    fn verify(self: Snapshot, allocator: std.mem.Allocator, io: std.Io) !void {
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, self.requested_path, allocator) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (resolved) |path| allocator.free(path);
        if (resolved) |path| {
            if (!std.mem.eql(u8, path, self.path)) return error.ReviewedPkgbuildChanged;
        } else if (self.content != null) return error.ReviewedPkgbuildChanged;
        const stat = std.Io.Dir.cwd().statFile(io, self.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (self.content == null) return else return error.ReviewedPkgbuildChanged,
            else => return err,
        };
        if (self.content == null or stat.kind != .file or stat.inode != self.inode or stat.permissions.toMode() != self.permissions.toMode()) return error.ReviewedPkgbuildChanged;
        const current = try std.Io.Dir.cwd().readFileAlloc(io, self.path, allocator, .limited(32 * 1024 * 1024));
        defer allocator.free(current);
        if (!std.mem.eql(u8, current, self.content.?)) return error.ReviewedPkgbuildChanged;
    }

    fn stage(self: Snapshot, allocator: std.mem.Allocator, io: std.Io, content: []const u8) ![]u8 {
        var random: [16]u8 = undefined;
        io.random(&random);
        const path = try std.fmt.allocPrint(allocator, "{s}.shelly-{s}.tmp", .{ self.path, std.fmt.bytesToHex(random, .lower) });
        errdefer allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        try file.writeStreamingAll(io, content);
        try file.setPermissions(io, self.permissions);
        try file.sync(io);
        return path;
    }
};

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pkgbuild: Snapshot,
    srcinfo: Snapshot,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, pkgbuild_path: []const u8) !Transaction {
        const pkgbuild = try Snapshot.init(allocator, io, pkgbuild_path, true);
        errdefer pkgbuild.deinit(allocator);
        const srcinfo_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(pkgbuild.path).?, ".SRCINFO" });
        defer allocator.free(srcinfo_path);
        const srcinfo = try Snapshot.init(allocator, io, srcinfo_path, false);
        errdefer srcinfo.deinit(allocator);
        if (std.mem.eql(u8, pkgbuild.path, srcinfo.path) or (srcinfo.inode != null and srcinfo.inode == pkgbuild.inode)) return error.InvalidPkgbuildPath;
        return .{ .allocator = allocator, .io = io, .pkgbuild = pkgbuild, .srcinfo = srcinfo };
    }

    pub fn deinit(self: Transaction) void {
        self.pkgbuild.deinit(self.allocator);
        self.srcinfo.deinit(self.allocator);
    }

    pub fn commit(self: Transaction, pkgbuild: []const u8, srcinfo: []const u8) !void {
        return self.commitUsing(pkgbuild, srcinfo, std.Io.Dir.rename);
    }

    fn commitUsing(self: Transaction, pkgbuild: []const u8, srcinfo: []const u8, comptime rename: anytype) !void {
        const next_pkgbuild = try self.pkgbuild.stage(self.allocator, self.io, pkgbuild);
        defer self.remove(next_pkgbuild);
        const next_srcinfo = try self.srcinfo.stage(self.allocator, self.io, srcinfo);
        defer self.remove(next_srcinfo);
        const backup = try self.pkgbuild.stage(self.allocator, self.io, self.pkgbuild.content.?);
        var preserve_backup = false;
        defer if (preserve_backup) self.allocator.free(backup) else self.remove(backup);
        try self.pkgbuild.verify(self.allocator, self.io);
        try self.srcinfo.verify(self.allocator, self.io);
        try rename(.cwd(), next_pkgbuild, .cwd(), self.pkgbuild.path, self.io);
        rename(.cwd(), next_srcinfo, .cwd(), self.srcinfo.path, self.io) catch |err| {
            rename(.cwd(), backup, .cwd(), self.pkgbuild.path, self.io) catch {
                // Keep the original bytes recoverable if the filesystem also
                // refuses rollback (for example, it became read-only).
                preserve_backup = true;
                std.debug.print("Could not restore PKGBUILD; original saved at {s}\n", .{backup});
                return error.MetadataRollbackFailed;
            };
            return err;
        };
    }

    fn remove(self: Transaction, path: []u8) void {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        self.allocator.free(path);
    }
};

test "updpkgsums transaction publishes both files and detects concurrent changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = "original" });
    try temporary.dir.setFilePermissions(io, "PKGBUILD", .fromMode(0o640), .{});
    const path = try temporary.dir.realPathFileAlloc(io, "PKGBUILD", allocator);
    defer allocator.free(path);
    var transaction = try Transaction.init(allocator, io, path);
    defer transaction.deinit();
    try transaction.commit("updated", "metadata");
    try std.testing.expectEqual(@as(u32, 0o640), (try temporary.dir.statFile(io, "PKGBUILD", .{})).permissions.toMode() & 0o777);
    const metadata = try temporary.dir.readFileAlloc(io, ".SRCINFO", allocator, .unlimited);
    defer allocator.free(metadata);
    try std.testing.expectEqualStrings("metadata", metadata);
    try std.testing.expectError(error.ReviewedPkgbuildChanged, transaction.commit("overwrite", "overwrite"));
    var fresh = try Transaction.init(allocator, io, path);
    defer fresh.deinit();
    try temporary.dir.writeFile(io, .{ .sub_path = ".SRCINFO", .data = "concurrent edit" });
    try std.testing.expectError(error.ReviewedPkgbuildChanged, fresh.commit("overwrite", "overwrite"));
    const pkgbuild = try temporary.dir.readFileAlloc(io, "PKGBUILD", allocator, .unlimited);
    defer allocator.free(pkgbuild);
    try std.testing.expectEqualStrings("updated", pkgbuild);
}

test "updpkgsums transaction rolls back when second publication fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = "original" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".SRCINFO", .data = "original metadata" });
    const path = try temporary.dir.realPathFileAlloc(io, "PKGBUILD", allocator);
    defer allocator.free(path);
    var transaction = try Transaction.init(allocator, io, path);
    defer transaction.deinit();
    const FailingPublisher = struct {
        fn rename(old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8, operation_io: std.Io) !void {
            if (std.mem.endsWith(u8, new_path, ".SRCINFO")) return error.AccessDenied;
            try std.Io.Dir.rename(old_dir, old_path, new_dir, new_path, operation_io);
        }
    };
    try std.testing.expectError(error.AccessDenied, transaction.commitUsing("updated", "metadata", FailingPublisher.rename));
    const pkgbuild = try temporary.dir.readFileAlloc(io, "PKGBUILD", allocator, .unlimited);
    defer allocator.free(pkgbuild);
    const srcinfo = try temporary.dir.readFileAlloc(io, ".SRCINFO", allocator, .unlimited);
    defer allocator.free(srcinfo);
    try std.testing.expectEqualStrings("original", pkgbuild);
    try std.testing.expectEqualStrings("original metadata", srcinfo);
}

test "updpkgsums transaction preserves symlinks and detects newly created SRCINFO" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "Recipe", .data = "original" });
    try temporary.dir.writeFile(io, .{ .sub_path = "Metadata", .data = "old" });
    try temporary.dir.symLink(io, "Recipe", "PKGBUILD", .{});
    try temporary.dir.symLink(io, "Metadata", ".SRCINFO", .{});
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "PKGBUILD" });
    defer allocator.free(path);
    var transaction = try Transaction.init(allocator, io, path);
    defer transaction.deinit();
    try transaction.commit("updated", "metadata");
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try temporary.dir.statFile(io, "PKGBUILD", .{ .follow_symlinks = false })).kind);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try temporary.dir.statFile(io, ".SRCINFO", .{ .follow_symlinks = false })).kind);
    const content = try temporary.dir.readFileAlloc(io, "Metadata", allocator, .unlimited);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("metadata", content);
    var linked = try Transaction.init(allocator, io, path);
    defer linked.deinit();
    try temporary.dir.writeFile(io, .{ .sub_path = "OtherMetadata", .data = "other" });
    try temporary.dir.deleteFile(io, ".SRCINFO");
    try temporary.dir.symLink(io, "OtherMetadata", ".SRCINFO", .{});
    try std.testing.expectError(error.ReviewedPkgbuildChanged, linked.commit("overwrite", "overwrite"));
    try temporary.dir.deleteFile(io, ".SRCINFO");
    var absent = try Transaction.init(allocator, io, path);
    defer absent.deinit();
    try temporary.dir.writeFile(io, .{ .sub_path = ".SRCINFO", .data = "created concurrently" });
    try std.testing.expectError(error.ReviewedPkgbuildChanged, absent.commit("overwrite", "overwrite"));
}
