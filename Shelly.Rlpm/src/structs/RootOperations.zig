//! Mutation primitives. Resolve parents with openat2(IN_ROOT), then operate on
//! single names through held descriptors. Never change the caller's cwd/umask.
const std = @import("std");
const Root = @import("RootPath.zig");
const PayloadDurability = @import("PayloadDurability.zig");

pub const c = Root.c;

pub const Durability = union(enum) {
    immediate,
    batch: *PayloadDurability,

    fn before(self: Durability, fd: c_int) !void {
        switch (self) {
            .immediate => {},
            .batch => |tracker| try tracker.registerBeforeMutation(fd),
        }
    }

    fn after(self: Durability, fd: c_int) !void {
        if (self == .immediate) try sync(fd);
    }
};

pub const Parent = struct {
    fd: c_int,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    len: usize,

    pub fn name(self: *const Parent) [:0]const u8 {
        return self.buffer[0..self.len :0];
    }

    pub fn deinit(self: *Parent) void {
        _ = c.close(self.fd);
    }
};

pub fn parent(root: *const Root, path: []const u8) !Parent {
    _ = try Root.normalize(path);
    const leaf = std.fs.path.basename(path);
    const fd = (try root.open(std.fs.path.dirname(path) orelse ".", true)) orelse return error.ParentNotFound;
    errdefer _ = c.close(fd);
    if (!(try Root.state(fd)).directory()) return error.NotDirectory;
    var result: Parent = .{ .fd = fd, .len = leaf.len };
    @memcpy(result.buffer[0..leaf.len], leaf);
    result.buffer[leaf.len] = 0;
    return result;
}

pub fn failure() anyerror {
    return switch (std.c._errno().*) {
        c.ENOMEM => error.OutOfMemory,
        c.ENOSPC, c.EDQUOT => error.NoSpaceLeft,
        c.EACCES, c.EPERM => error.PathPermissionDenied,
        c.EROFS => error.ReadOnlyFilesystem,
        c.ENOENT => error.FileNotFound,
        c.EEXIST => error.PathAlreadyExists,
        c.ENOTEMPTY => error.DirectoryNotEmpty,
        c.EISDIR, c.ENOTDIR => error.PathTypeConflict,
        c.EXDEV => error.CrossDeviceRename,
        else => error.FilesystemWriteFailed,
    };
}

pub fn sync(fd: c_int) !void {
    // O_PATH descriptors cannot be fsynced. Reopen the held directory itself.
    const writable = c.openat(fd, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (writable < 0) return failure();
    defer _ = c.close(writable);
    if (c.fsync(writable) != 0) return failure();
}

pub fn mkdirs(root: *const Root, path: []const u8) !void {
    return mkdirsWithDurability(root, path, .immediate);
}

pub fn mkdirsWithDurability(root: *const Root, path: []const u8, durability: Durability) !void {
    _ = try Root.normalize(path);
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
        const prefix = path[0..end];
        if (try root.inspect(prefix, true)) |state| {
            if (!state.directory()) return error.NotDirectory;
        } else {
            var p = try parent(root, prefix);
            defer p.deinit();
            try durability.before(p.fd);
            if (c.mkdirat(p.fd, p.name(), 0o755) != 0) return failure();
            const fd = c.openat(p.fd, p.name(), c.O_RDONLY | c.O_NOFOLLOW | c.O_DIRECTORY | c.O_CLOEXEC);
            if (fd < 0) return failure();
            defer _ = c.close(fd);
            if (c.fchmod(fd, 0o755) != 0) return failure();
            try durability.after(p.fd);
        }
        end += 1;
    }
}

pub fn remove(root: *const Root, path: []const u8, directory: bool) !void {
    return removeWithDurability(root, path, directory, .immediate);
}

pub fn removeWithDurability(
    root: *const Root,
    path: []const u8,
    directory: bool,
    durability: Durability,
) !void {
    var p = parent(root, path) catch |err| switch (err) {
        error.ParentNotFound => return,
        else => return err,
    };
    defer p.deinit();
    try durability.before(p.fd);
    if (c.unlinkat(p.fd, p.name(), if (directory) c.AT_REMOVEDIR else 0) != 0) {
        const e = std.c._errno().*;
        if (e == c.ENOENT or (directory and (e == c.ENOTEMPTY or e == c.EEXIST or e == c.EBUSY))) return;
        return failure();
    }
    try durability.after(p.fd);
}

pub fn rename(root: *const Root, from: []const u8, to: []const u8) !void {
    return renameWithDurability(root, from, to, .immediate);
}

pub fn renameWithDurability(
    root: *const Root,
    from: []const u8,
    to: []const u8,
    durability: Durability,
) !void {
    var source = try parent(root, from);
    defer source.deinit();
    var target = try parent(root, to);
    defer target.deinit();
    try durability.before(source.fd);
    try durability.before(target.fd);
    if (c.renameat(source.fd, source.name(), target.fd, target.name()) != 0) return failure();
    try durability.after(source.fd);
    try durability.after(target.fd);
}

pub fn write(fd: c_int, name: [:0]const u8, bytes: []const u8) !void {
    const file = c.openat(
        fd,
        name,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (file < 0) return failure();
    defer _ = c.close(file);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(file, bytes.ptr + offset, bytes.len - offset);
        if (count < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return failure();
        }
        if (count == 0) return error.FilesystemWriteFailed;
        offset += @intCast(count);
    }
    if (c.fchmod(file, 0o644) != 0 or c.fsync(file) != 0) return failure();
}

/// A private sibling directory on the destination mount. libarchive only sees
/// /proc/self/fd/<held-stage>/entry; archive names and hardlinks never reach it.
pub const Stage = struct {
    destination: Parent,
    fd: c_int,
    label: [48:0]u8,
    durability: Durability,

    pub fn init(root: *const Root, io: std.Io, path: []const u8) !Stage {
        return initWithDurability(root, io, path, .immediate);
    }

    pub fn initWithDurability(
        root: *const Root,
        io: std.Io,
        path: []const u8,
        durability: Durability,
    ) !Stage {
        var p = try parent(root, path);
        errdefer p.deinit();
        var random: [16]u8 = undefined;
        std.Io.random(io, &random);
        var label: [48:0]u8 = @splat(0);
        _ = try std.fmt.bufPrintZ(&label, ".rlpm-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try durability.before(p.fd);
        if (c.mkdirat(p.fd, &label, 0o700) != 0) return failure();
        errdefer _ = c.unlinkat(p.fd, &label, c.AT_REMOVEDIR);
        const fd = c.openat(p.fd, &label, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return failure();
        return .{
            .destination = p,
            .fd = fd,
            .label = label,
            .durability = durability,
        };
    }

    pub fn deinit(self: *Stage) !void {
        defer self.destination.deinit();
        defer _ = c.close(self.fd);
        if (c.unlinkat(self.fd, "entry", 0) != 0 and std.c._errno().* != c.ENOENT) {
            if (c.unlinkat(self.fd, "entry", c.AT_REMOVEDIR) != 0) return failure();
        }
        if (c.unlinkat(self.destination.fd, &self.label, c.AT_REMOVEDIR) != 0) return failure();
        try self.durability.after(self.destination.fd);
    }

    pub fn publish(self: *Stage) !void {
        if (c.renameat(self.fd, "entry", self.destination.fd, self.destination.name()) != 0)
            return failure();
        try self.durability.after(self.fd);
        try self.durability.after(self.destination.fd);
    }
};

/// Native pacsave rotations, enumerated after scripts so newly created suffixes
/// participate too. All operations remain within the held parent/root.
pub fn rotatePacsave(
    root: *const Root,
    io: std.Io,
    a: std.mem.Allocator,
    destination: []const u8,
) !void {
    return rotatePacsaveWithDurability(root, io, a, destination, .immediate);
}

pub fn rotatePacsaveWithDurability(
    root: *const Root,
    io: std.Io,
    a: std.mem.Allocator,
    destination: []const u8,
    durability: Durability,
) !void {
    var p = try parent(root, destination);
    defer p.deinit();
    const fd = c.openat(p.fd, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return failure();
    var dir: std.Io.Dir = .{ .handle = fd };
    defer dir.close(io);

    const Item = struct {
        number: u64,
        name: []const u8,
    };
    var entries: std.ArrayList(Item) = .empty;
    defer entries.deinit(a);
    const prefix = try std.fmt.allocPrint(a, "{s}.", .{p.name()});
    defer a.free(prefix);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        if (!std.mem.startsWith(u8, item.name, prefix)) continue;
        const n = std.fmt.parseInt(u64, item.name[prefix.len..], 10) catch continue;
        if (n == 0 or n == std.math.maxInt(u64)) return error.InvalidBackup;
        const name = try a.dupe(u8, item.name);
        errdefer a.free(name);
        try entries.append(a, .{ .number = n, .name = name });
    }
    defer for (entries.items) |item|
        a.free(item.name);
    std.mem.sort(Item, entries.items, {}, struct {
        fn less(_: void, left: Item, right: Item) bool {
            return left.number > right.number;
        }
    }.less);
    try durability.before(fd);
    for (entries.items) |item| {
        const from = try a.dupeSentinel(u8, item.name, 0);
        defer a.free(from);
        const to = try std.fmt.allocPrintSentinel(a, "{s}{d}", .{ prefix, item.number + 1 }, 0);
        defer a.free(to);
        if (c.renameat(fd, from, fd, to) != 0) return failure();
    }
    if (try root.inspect(destination, false) != null) {
        const to = try std.fmt.allocPrintSentinel(a, "{s}.1", .{p.name()}, 0);
        defer a.free(to);
        if (c.renameat(fd, p.name(), fd, to) != 0) return failure();
    }
    try durability.after(fd);
}
