//! Owns the encoded mtree and libarchive parser. Entries borrow until next().
const std = @import("std");
const ArchiveReader = @import("ArchiveReader.zig");
const PackageFile = @import("PackageFile.zig");

const MtreeIterator = @This();
allocator: std.mem.Allocator,
bytes: []u8,
reader: ArchiveReader,

/// Takes ownership only on success.
pub fn initOwned(allocator: std.mem.Allocator, bytes: []u8) !MtreeIterator {
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .reader = try ArchiveReader.openMemory(bytes, .mtree),
    };
}

pub fn next(self: *MtreeIterator) !?PackageFile {
    var entry = (try self.reader.next()) orelse return null;
    entry.name = ArchiveReader.normalizedName(entry.name);
    return entry;
}

pub fn deinit(self: *MtreeIterator) void {
    self.reader.deinit();
    self.allocator.free(self.bytes);
    self.* = undefined;
}
