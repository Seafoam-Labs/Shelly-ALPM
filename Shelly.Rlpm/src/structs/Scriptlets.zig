//! Scriptlet source selection is the executor's responsibility: archive before
//! install/upgrade, current local install file after it, old local install file
//! on both sides of an explicit removal (before the local record is deleted).
const std = @import("std");
const Root = @import("RootPath.zig");
const c = @import("action_protocol").c;
const Process = @import("ActionProcess.zig");
const Owner = @import("Owner.zig");
const Package = @import("Package.zig");
const MemberReader = @import("MemberReader.zig");

pub const Function = enum { pre_install, post_install, pre_upgrade, post_upgrade, pre_remove, post_remove };

pub const Source = union(enum) { package: *const Package, file: []const u8 };

pub const Result = struct {
    process: ?Process.Result = null,
    cleanup_failed: bool = false,
};

/// Preserve the native inexpensive, comment-stripping, 1023-byte line scan.
pub fn contains(contents: []const u8, function: Function) bool {
    var offset: usize = 0;
    while (offset < contents.len) {
        const available = contents[offset..@min(contents.len, offset + 1023)];
        const count = if (std.mem.indexOfScalar(u8, available, '\n')) |index| index + 1 else available.len;
        const line = available[0..count];
        const visible = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        if (std.mem.indexOf(u8, visible, @tagName(function)) != null) return true;
        offset += count;
    }
    return false;
}

const Temporary = struct {
    parent: c_int,
    directory: c_int,
    name: [38:0]u8,

    fn create(io: std.Io, root: *const Root, contents: []const u8) !Temporary {
        if (try root.open("tmp", true)) |fd| {
            _ = c.close(fd);
        } else {
            if (c.mkdirat(root.fd, "tmp", 0o1777) == 0) {
                const created = (try root.open("tmp", true)) orelse return error.ScriptletTemporaryFailed;
                defer _ = c.close(created);
                // Preserve the native requested mode without changing the
                // parent's process-wide umask or following a replacement path.
                const writable = c.openat(created, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
                if (writable < 0) return error.ScriptletTemporaryFailed;
                defer _ = c.close(writable);
                if (c.fchmod(writable, 0o1777) != 0) return error.ScriptletTemporaryFailed;
            } else if (std.c._errno().* != c.EEXIST) return error.ScriptletTemporaryFailed;
        }
        const parent = (try root.open("tmp", true)) orelse return error.ScriptletTemporaryFailed;
        errdefer _ = c.close(parent);
        var random: [16]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        var name: [38:0]u8 = undefined;
        @memcpy(name[0..6], "alpm_z");
        @memcpy(name[6..38], &hex);
        name[38] = 0;
        if (c.mkdirat(parent, &name, 0o700) != 0) return error.ScriptletTemporaryFailed;
        errdefer _ = c.unlinkat(parent, &name, c.AT_REMOVEDIR);
        const directory = c.openat(parent, &name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (directory < 0) return error.ScriptletTemporaryFailed;
        errdefer _ = c.close(directory);
        const file = c.openat(
            directory,
            ".INSTALL",
            c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW,
            @as(c_uint, 0o644),
        );
        if (file < 0) return error.ScriptletTemporaryFailed;
        defer _ = c.close(file);
        errdefer _ = c.unlinkat(directory, ".INSTALL", 0);
        var offset: usize = 0;
        while (offset < contents.len) {
            const count = c.write(file, contents[offset..].ptr, contents.len - offset);
            if (count < 0 and std.c._errno().* == c.EINTR) continue;
            if (count <= 0) return error.ScriptletTemporaryFailed;
            offset += @intCast(count);
        }
        return .{
            .parent = parent,
            .directory = directory,
            .name = name,
        };
    }

    fn cleanup(self: *Temporary) bool {
        defer _ = c.close(self.directory);
        defer _ = c.close(self.parent);
        const removed = c.unlinkat(self.directory, ".INSTALL", 0) == 0 or std.c._errno().* == c.ENOENT;
        // Do not delete a replacement directory if the script renamed ours.
        var current: c.struct_stat = undefined;
        var held: c.struct_stat = undefined;
        if (c.fstat(self.directory, &held) != 0 or
            c.fstatat(
                self.parent,
                &self.name,
                &current,
                c.AT_SYMLINK_NOFOLLOW,
            ) != 0 or
            held.st_ino != current.st_ino or
            held.st_dev != current.st_dev)
            return false;
        return c.unlinkat(self.parent, &self.name, c.AT_REMOVEDIR) == 0 and removed;
    }
};

pub fn run(
    owner: *Owner,
    io: std.Io,
    root: *const Root,
    source: Source,
    function: Function,
    version: []const u8,
    old_version: ?[]const u8,
) !Result {
    try owner.checkCancelled();
    var reader = (switch (source) {
        .package => |package| package.openMember(owner.allocator, .install),
        .file => |path| MemberReader.openFile(owner.allocator, path),
    } catch |err| switch (err) {
        error.AccessDenied => return .{},
        else => return err,
    }) orelse return .{};
    defer reader.deinit();
    const contents = try reader.readAll(owner.allocator, 16 * 1024 * 1024);
    defer owner.allocator.free(contents);
    if (!contains(contents, function)) return .{};
    var temporary = try Temporary.create(io, root, contents);
    var cleaned = false;
    defer if (!cleaned) {
        _ = temporary.cleanup();
    };
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/tmp/{s}/.INSTALL", .{temporary.name});
    // Quote metadata instead of treating version strings as shell syntax.
    // Keep the sourced file's positional arguments empty, as in libalpm.
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(owner.allocator);
    try command.appendSlice(owner.allocator, ". ");
    try quote(owner.allocator, &command, path);
    try command.appendSlice(owner.allocator, "; ");
    try command.appendSlice(owner.allocator, @tagName(function));
    try command.append(owner.allocator, ' ');
    try quote(owner.allocator, &command, version);
    if (old_version) |old| {
        try command.append(owner.allocator, ' ');
        try quote(owner.allocator, &command, old);
    }
    const process = try Process.run(
        owner,
        io,
        .{
            .root = root,
            .argv = &.{ "/usr/bin/bash", "-c", command.items },
        },
    );
    const success = temporary.cleanup();
    cleaned = true;
    return .{ .process = process, .cleanup_failed = !success };
}

fn quote(a: std.mem.Allocator, command: *std.ArrayList(u8), value: []const u8) !void {
    try command.append(a, 39);
    for (value) |byte| {
        if (byte == 39) try command.appendSlice(a, "'\\''") else try command.append(a, byte);
    }
    try command.append(a, 39);
}
