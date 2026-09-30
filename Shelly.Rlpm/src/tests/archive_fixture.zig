const std = @import("std");

const Fixture = @This();
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});
const io = std.testing.io;
const allocator = std.testing.allocator;

pub const Entry = struct {
    path: []const u8,
    contents: []const u8 = "",
    kind: enum { file, directory, symlink, hardlink, fifo, character, block } = .file,
    target: ?[]const u8 = null,
    declared_size: ?usize = null,
    mode: ?u32 = null,
    mtime: i64 = 0,
    xattr: ?[]const u8 = null,
    capabilities: bool = false,
    sparse: bool = false,
    acl: bool = false,
};

pub const Compression = enum { none, zstd, gzip, xz, bzip2 };
temporary: std.testing.TmpDir,
path: [:0]u8,

pub fn init(entries: []const Entry, compression: Compression) !Fixture {
    var temporary = std.testing.tmpDir(.{});
    errdefer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/package.tar", .{directory}, 0);
    errdefer allocator.free(path);
    const writer = c.archive_write_new() orelse return error.OutOfMemory;
    defer _ = c.archive_write_free(writer);
    const filter = switch (compression) {
        .none => c.ARCHIVE_OK,
        .zstd => c.archive_write_add_filter_zstd(writer),
        .gzip => c.archive_write_add_filter_gzip(writer),
        .xz => c.archive_write_add_filter_xz(writer),
        .bzip2 => c.archive_write_add_filter_bzip2(writer),
    };
    try std.testing.expectEqual(c.ARCHIVE_OK, filter);
    const extended = for (entries) |item| {
        if (item.xattr != null or item.capabilities or item.sparse or item.acl) break true;
    } else false;
    try std.testing.expectEqual(
        c.ARCHIVE_OK,
        if (extended)
            c.archive_write_set_format_pax(writer)
        else
            c.archive_write_set_format_ustar(writer),
    );
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_open_filename(writer, path.ptr));
    for (entries) |item| {
        const entry = c.archive_entry_new() orelse return error.OutOfMemory;
        defer c.archive_entry_free(entry);
        const name = try allocator.dupeSentinel(u8, item.path, 0);
        defer allocator.free(name);
        const target = if (item.target) |value| try allocator.dupeSentinel(u8, value, 0) else null;
        defer if (target) |value| allocator.free(value);
        c.archive_entry_set_pathname(entry, name.ptr);
        c.archive_entry_set_perm(
            entry,
            item.mode orelse
                (if (item.kind == .directory)
                    @as(u32, 0o755)
                else
                    0o644),
        );
        c.archive_entry_set_mtime(entry, item.mtime, 0);
        if (item.xattr) |value| c.archive_entry_xattr_add_entry(entry, "user.rlpm", value.ptr, value.len);
        if (item.capabilities) {
            const caps = [_]u8{ 1, 0, 0, 2, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }; // CAP_NET_BIND_SERVICE effective+permitted
            c.archive_entry_xattr_add_entry(entry, "security.capability", &caps, caps.len);
        }
        if (item.acl) {
            _ = c.archive_entry_acl_add_entry(
                entry,
                c.ARCHIVE_ENTRY_ACL_TYPE_ACCESS,
                7,
                c.ARCHIVE_ENTRY_ACL_USER_OBJ,
                -1,
                null,
            );
            _ = c.archive_entry_acl_add_entry(
                entry,
                c.ARCHIVE_ENTRY_ACL_TYPE_ACCESS,
                5,
                c.ARCHIVE_ENTRY_ACL_GROUP_OBJ,
                -1,
                null,
            );
            _ = c.archive_entry_acl_add_entry(
                entry,
                c.ARCHIVE_ENTRY_ACL_TYPE_ACCESS,
                0,
                c.ARCHIVE_ENTRY_ACL_OTHER,
                -1,
                null,
            );
            _ = c.archive_entry_acl_add_entry(
                entry,
                c.ARCHIVE_ENTRY_ACL_TYPE_ACCESS,
                5,
                c.ARCHIVE_ENTRY_ACL_MASK,
                -1,
                null,
            );
            _ = c.archive_entry_acl_add_entry(
                entry,
                c.ARCHIVE_ENTRY_ACL_TYPE_ACCESS,
                4,
                c.ARCHIVE_ENTRY_ACL_USER,
                42,
                "fixture",
            );
        }
        c.archive_entry_set_filetype(entry, switch (item.kind) {
            .file => 0o100000,
            .directory => 0o040000,
            .symlink => 0o120000,
            .hardlink => 0,
            .fifo => 0o010000,
            .character => 0o020000,
            .block => 0o060000,
        });
        if (item.kind == .symlink) c.archive_entry_set_symlink(entry, target.?.ptr);
        if (item.kind == .hardlink) c.archive_entry_set_hardlink(entry, target.?.ptr);
        c.archive_entry_set_size(entry, @intCast(item.declared_size orelse item.contents.len));
        if (item.sparse) c.archive_entry_sparse_add_entry(entry, @intCast(item.contents.len - 4), 4);
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_header(writer, entry));
        if (item.contents.len != 0)
            try std.testing.expectEqual(
                @as(isize, @intCast(item.contents.len)),
                c.archive_write_data(
                    writer,
                    item.contents.ptr,
                    item.contents.len,
                ),
            );
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_finish_entry(writer));
    }
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_close(writer));
    return .{ .temporary = temporary, .path = path };
}

pub fn deinit(self: *Fixture) void {
    allocator.free(self.path);
    self.temporary.cleanup();
}

pub fn gzip(bytes: []const u8) ![]u8 {
    const writer = c.archive_write_new() orelse return error.OutOfMemory;
    defer _ = c.archive_write_free(writer);
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_add_filter_gzip(writer));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_format_raw(writer));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_bytes_per_block(writer, 0));
    const buffer = try allocator.alloc(u8, bytes.len + 4096);
    defer allocator.free(buffer);
    var used: usize = 0;
    try std.testing.expectEqual(
        c.ARCHIVE_OK,
        c.archive_write_open_memory(
            writer,
            buffer.ptr,
            buffer.len,
            &used,
        ),
    );
    const entry = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(entry);
    c.archive_entry_set_pathname(entry, "data");
    c.archive_entry_set_filetype(entry, 0o100000);
    c.archive_entry_set_size(entry, @intCast(bytes.len));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_header(writer, entry));
    try std.testing.expectEqual(
        @as(isize, @intCast(bytes.len)),
        c.archive_write_data(
            writer,
            bytes.ptr,
            bytes.len,
        ),
    );
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_close(writer));
    return allocator.dupe(u8, buffer[0..used]);
}
