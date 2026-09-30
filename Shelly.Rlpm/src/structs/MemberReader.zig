//! Independently owned package member stream. Local members are read verbatim,
//! including compressed mtree bytes; MtreeIterator handles their compression.
const std = @import("std");
const ArchiveReader = @import("ArchiveReader.zig");

const MemberReader = @This();
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
stream: union(enum) { archive: ArchiveReader, file: *c.FILE },

pub fn openFile(allocator: std.mem.Allocator, path: []const u8) !?MemberReader {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const sentinel = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(sentinel);
    const file = c.fopen(sentinel.ptr, "rb") orelse return switch (std.c._errno().*) {
        c.ENOENT => null,
        c.ENOMEM => error.OutOfMemory,
        c.EACCES => error.AccessDenied,
        else => error.InputOutput,
    };
    return .{ .stream = .{ .file = file } };
}

pub fn read(self: *MemberReader, buffer: []u8) !usize {
    return switch (self.stream) {
        .archive => |*reader| reader.read(buffer),
        .file => |file| blk: {
            const count = c.fread(buffer.ptr, 1, buffer.len, file);
            if (c.ferror(file) != 0) return error.InputOutput;
            break :blk count;
        },
    };
}

pub fn readAll(self: *MemberReader, allocator: std.mem.Allocator, limit: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = try self.read(&buffer);
        if (count == 0) break;
        if (count > limit - bytes.items.len) return error.MetadataTooLarge;
        try bytes.appendSlice(allocator, buffer[0..count]);
    }
    return bytes.toOwnedSlice(allocator);
}

pub fn deinit(self: *MemberReader) void {
    switch (self.stream) {
        .archive => |*reader| reader.deinit(),
        .file => |file| {
            _ = c.fclose(file);
        },
    }
    self.* = undefined;
}
