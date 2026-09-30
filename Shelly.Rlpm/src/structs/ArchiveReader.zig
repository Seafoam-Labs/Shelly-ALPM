//! Small libarchive reader. Never extracts paths or writes filesystem data.
//! Entry names/links are borrowed until next(); memory input must outlive deinit.
const std = @import("std");
const PackageFile = @import("PackageFile.zig");

const ArchiveReader = @This();
pub const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
});

pub const Format = enum { tar, mtree };
handle: *c.struct_archive,
/// Borrowed native header, valid until next(). The executor clones it before
/// replacing archive-controlled paths with confined staging paths.
current_entry: ?*c.struct_archive_entry = null,
file_size: ?u64 = null,

fn init(format: Format) !ArchiveReader {
    const handle = c.archive_read_new() orelse return error.OutOfMemory;
    errdefer _ = c.archive_read_free(handle);
    if (c.archive_read_support_filter_all(handle) != c.ARCHIVE_OK) return failure(handle);
    const status = switch (format) {
        .tar => c.archive_read_support_format_tar(handle),
        .mtree => c.archive_read_support_format_mtree(handle),
    };
    if (status != c.ARCHIVE_OK) return failure(handle);
    return .{ .handle = handle };
}

pub fn openFile(allocator: std.mem.Allocator, path: []const u8) !ArchiveReader {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const sentinel = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(sentinel);
    var result = try init(.tar);
    errdefer result.deinit();
    if (c.archive_read_open_filename(result.handle, sentinel.ptr, 64 * 1024) != c.ARCHIVE_OK)
        return failure(result.handle);
    var stat: c.struct_stat = undefined;
    if (c.stat(sentinel.ptr, &stat) != 0 or stat.st_size < 0) return error.ArchiveFailed;
    result.file_size = @intCast(stat.st_size);
    return result;
}

pub fn openMemory(bytes: []const u8, format: Format) !ArchiveReader {
    var result = try init(format);
    errdefer result.deinit();
    if (c.archive_read_open_memory(result.handle, bytes.ptr, bytes.len) != c.ARCHIVE_OK)
        return failure(result.handle);
    return result;
}

pub fn next(self: *ArchiveReader) !?PackageFile {
    var entry: ?*c.struct_archive_entry = null;
    const status = c.archive_read_next_header(self.handle, &entry);
    if (status == c.ARCHIVE_EOF) return null;
    if (status != c.ARCHIVE_OK) return failure(self.handle);
    self.current_entry = entry;
    const name = c.archive_entry_pathname(entry);
    if (name == null) return error.ArchiveFailed;
    const size = c.archive_entry_size(entry);
    if (size < 0) return error.InvalidArchiveEntry;
    const hardlink = c.archive_entry_hardlink(entry);
    const symlink = c.archive_entry_symlink(entry);
    const mode = c.archive_entry_mode(entry);
    return .{
        .name = std.mem.span(name),
        .size = @intCast(size),
        .mode = @intCast(mode),
        .kind = if (hardlink != null) .hardlink else switch (mode & 0o170000) {
            0o100000 => .regular,
            0o040000 => .directory,
            0o120000 => .symlink,
            else => .other,
        },
        .link_target = if (hardlink != null)
            std.mem.span(hardlink)
        else if (symlink != null)
            std.mem.span(symlink)
        else
            null,
    };
}

pub fn read(self: *ArchiveReader, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    const result = c.archive_read_data(self.handle, buffer.ptr, buffer.len);
    if (result < 0) return failure(self.handle);
    return @intCast(result);
}

pub fn readAll(self: *ArchiveReader, allocator: std.mem.Allocator, limit: usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = try self.read(&buffer);
        if (count == 0) break;
        if (count > limit - result.items.len) return error.MetadataTooLarge;
        try result.appendSlice(allocator, buffer[0..count]);
    }
    return result.toOwnedSlice(allocator);
}

pub fn skip(self: *ArchiveReader) !void {
    if (c.archive_read_data_skip(self.handle) != c.ARCHIVE_OK) return failure(self.handle);
}

pub fn finish(self: *ArchiveReader) !void {
    if (c.archive_read_close(self.handle) != c.ARCHIVE_OK) return failure(self.handle);
}

pub fn deinit(self: *ArchiveReader) void {
    _ = c.archive_read_free(self.handle);
    self.* = undefined;
}

pub fn normalizedName(path: []const u8) []const u8 {
    var result = path;
    while (std.mem.startsWith(u8, result, "./"))
        result = result[2..];
    return result;
}

fn failure(handle: *c.struct_archive) error{ OutOfMemory, ArchiveFailed } {
    return if (c.archive_errno(handle) == c.ENOMEM) error.OutOfMemory else error.ArchiveFailed;
}
