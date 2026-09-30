//! Linux root-relative inspection. No extraction and no path-based writes.
//! openat2 confines followed links to the held root; absolute symlinks retain
//! their literal package contents and resolve as they would inside a chroot.
const std = @import("std");
const ArchiveReader = @import("ArchiveReader.zig");
const Checksum = @import("Checksum.zig");

const Root = @This();
pub const c = @cImport({
    // Import ABI declarations only. glibc's fortified variadic inline wrappers
    // are not translatable by Zig; bounds are checked in terminated()/open().
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("sys/file.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/syscall.h");
    @cInclude("errno.h");
});
fd: c_int,

pub const State = struct {
    device: u64,
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime: i128,
    ctime: i128,
    mount_id: ?u64 = null,

    pub fn directory(self: State) bool {
        return self.mode & c.S_IFMT == c.S_IFDIR;
    }

    pub fn regular(self: State) bool {
        return self.mode & c.S_IFMT == c.S_IFREG;
    }

    pub fn symlink(self: State) bool {
        return self.mode & c.S_IFMT == c.S_IFLNK;
    }
};

pub const Capacity = struct {
    device: u64,
    block_size: u64,
    available: u64,
    total: u64,
    read_only: bool,
};

pub fn init(path: []const u8) !Root {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try terminated(&buffer, path);
    const fd = c.open(name, c.O_PATH | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return failure();
    return .{ .fd = fd };
}

pub fn deinit(self: *Root) void {
    _ = c.close(self.fd);
    self.* = undefined;
}

fn terminated(buffer: []u8, path: []const u8) ![:0]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    return std.fmt.bufPrintZ(buffer, "{s}", .{path}) catch return error.NameTooLong;
}

/// Validate canonical archive/DB names before they become operations. Leading
/// ./ is conventional tar syntax; internal dot components are rejected.
pub fn normalize(path: []const u8) ![]const u8 {
    const name = ArchiveReader.normalizedName(path);
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, 0) != null or
        name.len >= std.fs.max_path_bytes)
        return error.UnsafeArchivePath;
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "/"), '/');
    while (parts.next()) |part|
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.UnsafeArchivePath;
    return name;
}

/// The caller owns the returned descriptor. No fallback to unconstrained open.
pub fn open(self: *const Root, path: []const u8, follow: bool) !?c_int {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try terminated(&buffer, path);

    const How = extern struct {
        flags: u64,
        mode: u64 = 0,
        resolve: u64 = 0x10 | 0x02,
    }; // IN_ROOT | NO_MAGICLINKS
    const how: How = .{
        .flags = @intCast(c.O_PATH | c.O_CLOEXEC | (if (follow) @as(c_int, 0) else c.O_NOFOLLOW)),
    };
    const result = c.syscall(c.SYS_openat2, self.fd, name.ptr, &how, @as(usize, @sizeOf(How)));
    if (result < 0) {
        if (std.c._errno().* == c.ENOENT or std.c._errno().* == c.ENOTDIR) return null;
        return failure();
    }
    return @intCast(result);
}

pub fn state(fd: c_int) !State {
    var info: c.struct_stat = undefined;
    if (c.fstat(fd, &info) != 0) return failure();
    var extended: c.struct_statx = undefined;
    const mount_id: ?u64 = if (c.statx(
        fd,
        "",
        c.AT_EMPTY_PATH | c.AT_SYMLINK_NOFOLLOW,
        c.STATX_MNT_ID,
        &extended,
    ) == 0 and
        extended.stx_mask & c.STATX_MNT_ID != 0)
        extended.stx_mnt_id
    else
        null;
    return .{
        .device = info.st_dev,
        .inode = info.st_ino,
        .mode = info.st_mode,
        .uid = info.st_uid,
        .gid = info.st_gid,
        .size = @intCast(@max(0, info.st_size)),
        .mtime = @as(i128, info.st_mtim.tv_sec) * std.time.ns_per_s + info.st_mtim.tv_nsec,
        .ctime = @as(i128, info.st_ctim.tv_sec) * std.time.ns_per_s + info.st_ctim.tv_nsec,
        .mount_id = mount_id,
    };
}

pub fn inspect(self: *const Root, path: []const u8, follow: bool) !?State {
    const fd = (try self.open(path, follow)) orelse return null;
    defer _ = c.close(fd);
    return try state(fd);
}

/// Find the existing ancestor used for mount/access estimates. A future
/// executor must open the immediate parent again after planned mkdirs/removals.
pub fn ancestor(self: *const Root, path: []const u8) !c_int {
    var parent = std.fs.path.dirname(path) orelse ".";
    while (true) {
        if (try self.open(parent, true)) |fd| {
            const info = state(fd) catch |err| {
                _ = c.close(fd);
                return err;
            };
            if (info.directory()) return fd;
            _ = c.close(fd);
        }
        if (std.mem.eql(u8, parent, ".")) return error.InvalidRoot;
        parent = std.fs.path.dirname(parent) orelse ".";
    }
}

/// Check the affected mount as well as the containing directory. File bind
/// mounts can be read-only even when their parent is writable.
pub fn access(self: *const Root, path: []const u8) !void {
    const parent = try self.ancestor(path);
    defer _ = c.close(parent);
    try writable(parent);
    if (try self.open(path, false)) |fd| {
        defer _ = c.close(fd);
        const info = try state(fd);
        const directory = try state(parent);
        if (directory.mode & 0o1000 != 0 and c.geteuid() != 0 and c.geteuid() != directory.uid and
            c.geteuid() != info.uid)
            return error.PathPermissionDenied;
        if (capacity(fd)) |cap| {
            if (cap.read_only) return error.ReadOnlyFilesystem;
        } else |_| {}
    }
    if (capacity(parent)) |cap| {
        if (cap.read_only) return error.ReadOnlyFilesystem;
    } else |_| {}
}

pub fn capacity(fd: c_int) !Capacity {
    var info: c.struct_statvfs = undefined;
    if (c.fstatvfs(fd, &info) != 0) return error.CapacityUnavailable;
    const block = if (info.f_frsize != 0) info.f_frsize else info.f_bsize;
    if (block == 0) return error.CapacityUnavailable;
    return .{
        .device = (try state(fd)).device,
        .block_size = block,
        .available = info.f_bavail,
        .total = info.f_blocks,
        .read_only = info.f_flag & c.ST_RDONLY != 0,
    };
}

pub fn writable(fd: c_int) !void {
    if (c.faccessat(fd, ".", c.W_OK | c.X_OK, c.AT_EACCESS) != 0) return failure();
}

pub fn hash(self: *const Root, io: std.Io, path: []const u8, output: *[32]u8) !bool {
    const fd = (try self.open(path, true)) orelse return false;
    defer _ = c.close(fd);
    const before = try state(fd);
    if (!before.regular()) return false;
    var buffer: [80]u8 = undefined;
    const held = try std.fmt.bufPrint(&buffer, "/proc/{d}/fd/{d}", .{ c.getpid(), fd });
    const digest = try Checksum.file(.md5, io, held);
    output.* = digest;
    if (!std.meta.eql(before, try state(fd))) return error.StaleFilesystemState;
    return true;
}

fn failure() anyerror {
    return switch (std.c._errno().*) {
        c.ENOMEM => error.OutOfMemory,
        c.EACCES, c.EPERM => error.PathPermissionDenied,
        c.EROFS => error.ReadOnlyFilesystem,
        c.ELOOP, c.EXDEV => error.UnsafeSymlink,
        c.ENOSYS, c.EINVAL => error.RootConfinementUnavailable,
        else => error.FilesystemInspectionFailed,
    };
}
