//! Temporary access to builder-owned package directories. Pin each changed
//! inode so restoration cannot follow a renamed path or a substituted symlink.
//! Package modes remain separate from the permissions needed by tidy/archiving.
const std = @import("std");
const archive = @import("archive");
const linux = std.os.linux;
const op_context = @import("operation_context");

pub const Access = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: ?*op_context.Operation = null,
    changes: std.ArrayList(Change) = .empty,
    modes: std.ArrayList(archive.ModeOverride) = .empty,
    failure_path: ?[]u8 = null,

    const Change = struct {
        path: []u8,
        handle: i32,
        mode: u32,
        active: bool = false,
    };

    /// The caller must restore before deinit, including on error/cancellation.
    pub fn deinit(self: *Access) void {
        for (self.changes.items) |change| {
            _ = linux.close(change.handle);
            self.allocator.free(change.path);
        }
        self.changes.deinit(self.allocator);
        self.modes.deinit(self.allocator);
        if (self.failure_path) |path| self.allocator.free(path);
    }

    /// parent is a trusted staging-directory handle; name is a single component.
    /// Grant access top-down before attempting to enumerate any children.
    pub fn prepare(self: *Access, parent: std.Io.Dir, name: []const u8) !void {
        try validateName(name);
        try self.visit(parent, name, "");
        std.mem.sort(archive.ModeOverride, self.modes.items, {}, struct {
            fn before(_: void, left: archive.ModeOverride, right: archive.ModeOverride) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.before);
    }

    fn visit(self: *Access, parent: std.Io.Dir, name: []const u8, path: []const u8) anyerror!void {
        self.visitDirectory(parent, name, path) catch |err| {
            if (self.failure_path == null)
                self.failure_path = self.allocator.dupe(u8, path) catch null;
            return err;
        };
    }

    fn visitDirectory(self: *Access, parent: std.Io.Dir, name: []const u8, path: []const u8) !void {
        if (self.operation) |operation| try operation.checkCancelled();
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        // O_PATH works even for mode 0000; DIRECTORY|NOFOLLOW rejects symlinks.
        const result = linux.openat(parent.handle, name_z, .{
            .PATH = true,
            .DIRECTORY = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0);
        try checkResult(result);
        const handle: i32 = @intCast(result);
        var retained = false;
        defer if (!retained) {
            _ = linux.close(handle);
        };

        var stat: linux.Statx = undefined;
        try checkResult(linux.statx(handle, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &stat));
        if (!stat.mask.MODE) return error.PackageDirectoryModeUnavailable;
        const mode: u32 = stat.mode & 0o7777;
        if (mode & 0o700 != 0o700) {
            if (!stat.mask.UID or stat.uid != linux.geteuid()) return error.PackageDirectoryNotOwned;
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer if (!retained) self.allocator.free(owned_path);
            try self.changes.append(self.allocator, .{ .path = owned_path, .handle = handle, .mode = mode });
            retained = true;
            try self.modes.append(self.allocator, .{ .path = owned_path, .mode = mode });
            try chmodPinned(handle, mode | 0o700);
            self.changes.items[self.changes.items.len - 1].active = true;
        }

        const pinned: std.Io.Dir = .{ .handle = handle };
        var directory = try pinned.openDir(self.io, ".", .{ .iterate = true, .follow_symlinks = false });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (self.operation) |operation| try operation.checkCancelled();
            // stat without following links also supports filesystems returning
            // unknown directory-entry types.
            const child = try directory.statFile(self.io, entry.name, .{ .follow_symlinks = false });
            if (child.kind != .directory) continue;
            const child_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            defer self.allocator.free(child_path);
            try self.visit(directory, entry.name, child_path);
        }
    }

    /// Restore children before parents. Raw descriptor syscalls deliberately
    /// remain usable after the operation's cancellable IO has been cancelled.
    /// Attempt every restoration even if one fails.
    pub fn restore(self: *Access) !void {
        var first_error: ?anyerror = null;
        var index = self.changes.items.len;
        while (index > 0) {
            index -= 1;
            const change = &self.changes.items[index];
            if (!change.active) continue;
            chmodPinned(change.handle, change.mode) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            change.active = false;
        }
        if (first_error) |err| return err;
    }
};

/// Only staging payloads use this recovery. Build-root writability checks
/// remain strict. Symlink roots are unlinked, and never traversed or chmodded.
pub fn removeTree(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, name: []const u8) !void {
    try validateName(name);
    const stat = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return parent.deleteFile(io, name);
    var access: Access = .{ .allocator = allocator, .io = io };
    defer access.deinit();
    errdefer access.restore() catch {};
    try access.prepare(parent, name);
    try parent.deleteTree(io, name);
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidPackageDirectory;
}

fn chmodPinned(handle: i32, mode: u32) !void {
    const result = linux.fchmodat2(handle, "", mode, linux.AT.EMPTY_PATH);
    switch (linux.errno(result)) {
        .SUCCESS => return,
        // Older kernels lack fchmodat2/AT_EMPTY_PATH. This proc magic link
        // refers to our still-open descriptor, never to a package-supplied path.
        .NOSYS, .INVAL, .OPNOTSUPP => {
            var buffer: [64]u8 = undefined;
            const path = try std.fmt.bufPrintZ(&buffer, "/proc/self/fd/{d}", .{handle});
            try checkResult(linux.fchmodat(linux.AT.FDCWD, path, mode));
        },
        else => try checkResult(result),
    }
}

fn checkResult(result: usize) !void {
    return switch (linux.errno(result)) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR, .LOOP => error.NotDir,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        else => error.Unexpected,
    };
}

test "PackageBuilder permission restoration pins inodes and survives cancellation" {
    if (linux.geteuid() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "payload", .fromMode(0o700));
    try tmp.dir.createDir(io, "outside", .fromMode(0o700));
    try tmp.dir.setFilePermissions(io, "payload", .fromMode(0o000), .{});
    defer tmp.dir.setFilePermissions(io, "payload", .fromMode(0o700), .{}) catch {};
    defer tmp.dir.setFilePermissions(io, "renamed", .fromMode(0o700), .{}) catch {};
    var context = op_context.OperationContext.init(testing.allocator, io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .aur, .kind = .build, .subject = "permissions" });
    defer operation.finish(.cancelled);
    var access: Access = .{ .allocator = testing.allocator, .io = io, .operation = &operation };
    defer access.deinit();
    defer access.restore() catch {};
    try access.prepare(tmp.dir, "payload");
    try testing.expectEqual(@as(u32, 0o700), (try tmp.dir.statFile(io, "payload", .{})).permissions.toMode() & 0o7777);
    try tmp.dir.rename("payload", tmp.dir, "renamed", io);
    try tmp.dir.symLink(io, "outside", "payload", .{ .is_directory = true });
    context.cancel();
    try testing.expectError(error.Cancelled, operation.checkCancelled());
    try access.restore();
    try testing.expectEqual(@as(u32, 0), (try tmp.dir.statFile(io, "renamed", .{})).permissions.toMode() & 0o7777);
    try testing.expectEqual(@as(u32, 0o700), (try tmp.dir.statFile(io, "outside", .{})).permissions.toMode() & 0o7777);
    // Remove the link before the defer that repairs permissions for tmp cleanup.
    try tmp.dir.deleteFile(io, "payload");
}

test "PackageBuilder restricted cleanup never changes external symlink targets" {
    if (linux.geteuid() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "payload/locked");
    try tmp.dir.createDir(io, "outside", .fromMode(0o700));
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/keep", .data = "unchanged" });
    try tmp.dir.symLink(io, "../../outside", "payload/locked/link", .{ .is_directory = true });
    try tmp.dir.symLink(io, "../../missing", "payload/locked/dangling", .{});
    try tmp.dir.setFilePermissions(io, "outside", .fromMode(0o500), .{});
    defer tmp.dir.setFilePermissions(io, "outside", .fromMode(0o700), .{}) catch {};
    try tmp.dir.setFilePermissions(io, "payload/locked", .fromMode(0o000), .{});
    defer tmp.dir.setFilePermissions(io, "payload/locked", .fromMode(0o700), .{}) catch {};
    try removeTree(testing.allocator, io, tmp.dir, "payload");
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "payload", .{}));
    try testing.expectEqual(@as(u32, 0o500), (try tmp.dir.statFile(io, "outside", .{})).permissions.toMode() & 0o7777);
    const kept = try tmp.dir.readFileAlloc(io, "outside/keep", testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("unchanged", kept);
    try tmp.dir.symLink(io, "outside", "payload", .{ .is_directory = true });
    var access: Access = .{ .allocator = testing.allocator, .io = io };
    defer access.deinit();
    try testing.expectError(error.NotDir, access.prepare(tmp.dir, "payload"));
    try removeTree(testing.allocator, io, tmp.dir, "payload");
    try testing.expectEqual(@as(u32, 0o500), (try tmp.dir.statFile(io, "outside", .{})).permissions.toMode() & 0o7777);
    try testing.expectError(error.InvalidPackageDirectory, removeTree(testing.allocator, io, tmp.dir, "../outside"));
}

test "PackageBuilder refuses permission repair of foreign-owned directories" {
    if (linux.geteuid() == 0) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    // procfs supplies a root-owned, non-owner-writable directory without
    // requiring privileged setup or changing any host permissions.
    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{}) catch return error.SkipZigTest;
    defer proc.close(io);
    var stat: linux.Statx = undefined;
    const result = linux.statx(proc.handle, "sys", linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true, .UID = true }, &stat);
    if (linux.errno(result) != .SUCCESS or !stat.mask.UID or !stat.mask.MODE or
        stat.uid == linux.geteuid() or stat.mode & 0o700 == 0o700) return error.SkipZigTest;
    var access: Access = .{ .allocator = testing.allocator, .io = io };
    defer access.deinit();
    defer access.restore() catch {};
    try testing.expectError(error.PackageDirectoryNotOwned, access.prepare(proc, "sys"));
    try testing.expectEqual(@as(usize, 0), access.changes.items.len);
}
