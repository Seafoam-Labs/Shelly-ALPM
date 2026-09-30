//! An anonymous, sealed Linux file. GPG and every archive reader open these exact
//! bytes, independently of renames or writes to the original/cache pathname.
const std = @import("std");

const ImmutableFile = @This();
const c = std.c;

fd: c_int,
name: [80]u8 = undefined,
name_len: usize = 0,

pub fn path(self: *const ImmutableFile) []const u8 {
    return self.name[0..self.name_len];
}

pub fn deinit(self: *ImmutableFile) void {
    _ = c.close(self.fd);
    self.* = undefined;
}

/// Retains the same sealed bytes for an independently owned transaction plan.
pub fn clone(self: *const ImmutableFile) !ImmutableFile {
    const fd = c.fcntl(self.fd, c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (fd < 0) return failure();
    var result: ImmutableFile = .{ .fd = fd };
    errdefer result.deinit();
    result.name_len = (try std.fmt.bufPrint(&result.name, "/proc/{d}/fd/{d}", .{ c.getpid(), fd })).len;
    return result;
}

fn create() !ImmutableFile {
    const fd = c.memfd_create("rlpm-verified", c.MFD.CLOEXEC | c.MFD.ALLOW_SEALING);
    if (fd < 0) return failure();
    var result: ImmutableFile = .{ .fd = fd };
    errdefer result.deinit();
    result.name_len = (try std.fmt.bufPrint(&result.name, "/proc/{d}/fd/{d}", .{ c.getpid(), fd })).len;
    return result;
}

fn write(self: *ImmutableFile, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(self.fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
            return failure();
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn seal(self: *ImmutableFile) !void {
    if (c.fcntl(
        self.fd,
        c.F.ADD_SEALS,
        @as(c_int, c.F.SEAL_WRITE | c.F.SEAL_GROW | c.F.SEAL_SHRINK | c.F.SEAL_SEAL),
    ) < 0)
        return failure();
}

pub fn fromBytes(bytes: []const u8) !ImmutableFile {
    var result = try create();
    errdefer result.deinit();
    try result.write(bytes);
    try result.seal();
    return result;
}

pub fn copy(io: std.Io, source: []const u8) !ImmutableFile {
    return copyOptions(io, source, .{}, null);
}

/// Untrusted worker outputs must be regular files, never followed symlinks.
pub fn copyRegular(io: std.Io, source: []const u8, maximum: ?u64) !ImmutableFile {
    // O_PATH inspects FIFOs/devices without blocking or opening the device.
    // Reopen the retained regular inode, never the replaceable worker pathname.
    const input = try std.Io.Dir.cwd().openFile(io, source, .{ .path_only = true, .follow_symlinks = false });
    defer input.close(io);
    if ((try input.stat(io)).kind != .file) return error.NotRegularFile;
    var buffer: [80]u8 = undefined;
    const retained = try std.fmt.bufPrint(&buffer, "/proc/{d}/fd/{d}", .{ c.getpid(), input.handle });
    return copyOptions(io, retained, .{}, maximum);
}

fn copyOptions(
    io: std.Io,
    source: []const u8,
    options: std.Io.Dir.OpenFileOptions,
    maximum: ?u64,
) !ImmutableFile {
    const input = try std.Io.Dir.cwd().openFile(io, source, options);
    defer input.close(io);
    const stat = try input.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (maximum) |max|
        if (stat.size > max) return error.SizeExceeded;
    var result = try create();
    errdefer result.deinit();
    var buffer: [64 * 1024]u8 = undefined;
    var remaining = stat.size;
    while (remaining != 0) {
        const chunk = buffer[0..@min(remaining, buffer.len)];
        const n = input.readStreaming(io, &.{chunk}) catch |err| switch (err) {
            error.EndOfStream => return error.FileChanged,
            else => return err,
        };
        if (n == 0) return error.FileChanged;
        try result.write(buffer[0..n]);
        remaining -= n;
    }
    if ((try input.stat(io)).size != stat.size) return error.FileChanged;
    const output: std.Io.File = .{ .handle = result.fd, .flags = .{ .nonblocking = false } };
    try output.setTimestamps(io, .{ .modify_timestamp = .{ .new = stat.mtime } });
    try result.seal();
    return result;
}

fn failure() anyerror {
    return switch (@as(c.E, @enumFromInt(c._errno().*))) {
        .NOMEM => error.OutOfMemory,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOSPC => error.NoSpaceLeft,
        else => error.SnapshotFailed,
    };
}
