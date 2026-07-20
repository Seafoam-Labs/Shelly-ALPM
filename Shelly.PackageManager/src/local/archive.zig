const std = @import("std");

const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// These POSIX file type constants are macros which Zig 0.16's C translator
// cannot expand from archive_entry.h on every libc version.
const ae_ifreg: c_uint = 0o100000;
const ae_ifdir: c_uint = 0o040000;
const ae_iflnk: c_uint = 0o120000;

pub const Error = error{
    ArchiveCreateFailed,
    ArchiveOpenFailed,
    ArchiveReadFailed,
    ArchiveWriteFailed,
    InvalidEntryPath,
    EntryTooLarge,
};

pub const EntryKind = enum {
    regular_file,
    directory,
    symbolic_link,
    other,
};

/// Metadata borrowed from a Reader. `path` remains valid until the next call
/// to `next` or until the reader is deinitialized.
pub const Entry = struct {
    path: []const u8,
    kind: EntryKind,
    size: u64,
    permissions: u32,
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    handle: *c.struct_archive,
    path_z: [:0]u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Reader {
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);

        const handle = c.archive_read_new() orelse return Error.ArchiveCreateFailed;
        errdefer _ = c.archive_read_free(handle);

        try requireStatus(c.archive_read_support_filter_none(handle));
        try requireStatus(c.archive_read_support_filter_gzip(handle));
        try requireStatus(c.archive_read_support_filter_zstd(handle));
        try requireStatus(c.archive_read_support_format_tar(handle));

        if (c.archive_read_open_filename(handle, path_z.ptr, 64 * 1024) < c.ARCHIVE_WARN)
            return Error.ArchiveOpenFailed;

        return .{
            .allocator = allocator,
            .handle = handle,
            .path_z = path_z,
        };
    }

    pub fn deinit(self: *Reader) void {
        _ = c.archive_read_free(self.handle);
        self.allocator.free(self.path_z);
        self.* = undefined;
    }

    pub fn next(self: *Reader) !?Entry {
        var raw_entry: ?*c.struct_archive_entry = null;
        const status = c.archive_read_next_header(self.handle, &raw_entry);
        if (status == c.ARCHIVE_EOF) return null;
        if (status < c.ARCHIVE_WARN or raw_entry == null) return Error.ArchiveReadFailed;

        const entry = raw_entry.?;
        const pathname = c.archive_entry_pathname_utf8(entry) orelse
            c.archive_entry_pathname(entry) orelse return Error.InvalidEntryPath;
        const raw_size = c.archive_entry_size(entry);

        return .{
            .path = std.mem.span(pathname),
            .kind = switch (c.archive_entry_filetype(entry)) {
                ae_ifreg => .regular_file,
                ae_ifdir => .directory,
                ae_iflnk => .symbolic_link,
                else => .other,
            },
            .size = if (raw_size > 0) @intCast(raw_size) else 0,
            .permissions = @intCast(c.archive_entry_perm(entry)),
        };
    }

    /// Reads bytes belonging to the current entry. A return value of zero is
    /// end-of-entry.
    pub fn read(self: *Reader, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        const amount = c.archive_read_data(self.handle, buffer.ptr, buffer.len);
        if (amount < 0) return Error.ArchiveReadFailed;
        return @intCast(amount);
    }

    pub fn readPrefix(self: *Reader, buffer: []u8) !usize {
        var used: usize = 0;
        while (used < buffer.len) {
            const amount = try self.read(buffer[used..]);
            if (amount == 0) break;
            used += amount;
        }
        return used;
    }

    pub fn skip(self: *Reader) !void {
        try requireStatus(c.archive_read_data_skip(self.handle));
    }
};

fn requireStatus(status: c_int) !void {
    if (status < c.ARCHIVE_WARN) return Error.ArchiveReadFailed;
}

/// Normalizes an archive entry into a path relative to an extraction root.
/// Absolute paths, backslashes, and parent traversal are rejected.
pub fn normalizeEntryPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null)
        return Error.InvalidEntryPath;

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return Error.InvalidEntryPath;
        if (normalized.items.len != 0) try normalized.append(allocator, '/');
        try normalized.appendSlice(allocator, component);
    }

    if (normalized.items.len == 0) return Error.InvalidEntryPath;
    return normalized.toOwnedSlice(allocator);
}

// Test fixture support is intentionally kept in this internal module rather
// than making tests depend on external `tar`, `gzip`, or `zstd` executables.
pub const FixtureCompression = enum { none, gzip, zstd };

pub const FixtureEntry = struct {
    path: [:0]const u8,
    contents: []const u8,
    permissions: u32 = 0o644,
};

pub fn writeFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
    compression: FixtureCompression,
    entries: []const FixtureEntry,
) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const handle = c.archive_write_new() orelse return Error.ArchiveCreateFailed;
    defer _ = c.archive_write_free(handle);

    const filter_status = switch (compression) {
        .none => c.archive_write_add_filter_none(handle),
        .gzip => c.archive_write_add_filter_gzip(handle),
        .zstd => c.archive_write_add_filter_zstd(handle),
    };
    if (filter_status < c.ARCHIVE_WARN) return Error.ArchiveWriteFailed;
    if (c.archive_write_set_format_pax_restricted(handle) < c.ARCHIVE_WARN)
        return Error.ArchiveWriteFailed;
    if (c.archive_write_open_filename(handle, path_z.ptr) < c.ARCHIVE_WARN)
        return Error.ArchiveWriteFailed;
    defer _ = c.archive_write_close(handle);

    for (entries) |fixture| {
        const entry = c.archive_entry_new() orelse return Error.ArchiveCreateFailed;
        defer c.archive_entry_free(entry);
        c.archive_entry_set_pathname(entry, fixture.path.ptr);
        c.archive_entry_set_filetype(entry, ae_ifreg);
        c.archive_entry_set_perm(entry, @intCast(fixture.permissions));
        c.archive_entry_set_size(entry, @intCast(fixture.contents.len));
        if (c.archive_write_header(handle, entry) < c.ARCHIVE_WARN)
            return Error.ArchiveWriteFailed;
        if (fixture.contents.len != 0) {
            const amount = c.archive_write_data(handle, fixture.contents.ptr, fixture.contents.len);
            if (amount < 0 or amount != fixture.contents.len) return Error.ArchiveWriteFailed;
        }
    }
}

test "archive reader supports gzip and zstd tar streams" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (.{ FixtureCompression.gzip, FixtureCompression.zstd }) |compression| {
        const extension = if (compression == .gzip) "gz" else "zst";
        const path = try std.fmt.allocPrint(
            testing.allocator,
            ".zig-cache/tmp/{s}/fixture.tar.{s}",
            .{ tmp.sub_path, extension },
        );
        defer testing.allocator.free(path);

        try writeFixture(testing.allocator, path, compression, &.{
            .{ .path = "bin/demo", .contents = "\x7fELFpayload", .permissions = 0o755 },
        });

        var reader = try Reader.init(testing.allocator, path);
        defer reader.deinit();
        const entry = (try reader.next()).?;
        try testing.expectEqualStrings("bin/demo", entry.path);
        try testing.expectEqual(EntryKind.regular_file, entry.kind);
        var magic: [4]u8 = undefined;
        try testing.expectEqual(@as(usize, 4), try reader.readPrefix(&magic));
        try testing.expectEqualSlices(u8, "\x7fELF", &magic);
        try testing.expect((try reader.next()) == null);
    }
}

test "archive paths cannot escape the extraction root" {
    const testing = std.testing;
    try testing.expectError(Error.InvalidEntryPath, normalizeEntryPath(testing.allocator, "../../etc/passwd"));
    try testing.expectError(Error.InvalidEntryPath, normalizeEntryPath(testing.allocator, "/etc/passwd"));
    try testing.expectError(Error.InvalidEntryPath, normalizeEntryPath(testing.allocator, "..\\etc\\passwd"));

    const normalized = try normalizeEntryPath(testing.allocator, "./usr//bin/demo");
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("usr/bin/demo", normalized);
}
