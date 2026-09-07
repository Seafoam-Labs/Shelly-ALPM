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
    ArchiveEntryCreateFailed,
    ArchiveWriteFailed,
    ArchiveCloseFailed,
    InvalidEntryPath,
    InvalidEntryTimestamp,
    EntryTooLarge,
    UnsupportedCompression,
    UnsupportedFileType,
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
    uid: i64,
    gid: i64,
    mtime: ?std.Io.Timestamp,
    link_target: ?[]const u8,
};

/// Ownership recorded in a package archive. This is deliberately independent
/// of the ownership of the staging tree on the host filesystem.
pub const VirtualOwnership = struct {
    uid: i64 = 0,
    gid: i64 = 0,
};

pub const OwnershipOverride = struct {
    path: []const u8,
    ownership: VirtualOwnership,
};

/// Metadata view used by both package and mtree generation. Package staging
/// always remains owned by the unprivileged build user; only this view is
/// written to the resulting archive.
pub const VirtualMetadata = struct {
    default_ownership: VirtualOwnership = .{},
    ownership_overrides: []const OwnershipOverride = &.{},
    ownership_overrides_sorted: bool = false,

    pub fn ownershipForPath(self: VirtualMetadata, path: []const u8) VirtualOwnership {
        if (self.ownership_overrides_sorted) {
            var low: usize = 0;
            var high = self.ownership_overrides.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                switch (std.mem.order(u8, path, self.ownership_overrides[middle].path)) {
                    .lt => high = middle,
                    .gt => low = middle + 1,
                    .eq => return self.ownership_overrides[middle].ownership,
                }
            }
            return self.default_ownership;
        }
        for (self.ownership_overrides) |override| {
            if (std.mem.eql(u8, override.path, path)) return override.ownership;
        }
        return self.default_ownership;
    }
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    handle: *c.struct_archive,
    output_path_z: [:0]u8,
    virtual_metadata: VirtualMetadata,
    closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        output_path: []const u8,
    ) !Writer {
        return initWithMetadata(allocator, io, output_path, .{});
    }

    pub fn initWithMetadata(
        allocator: std.mem.Allocator,
        io: std.Io,
        output_path: []const u8,
        virtual_metadata: VirtualMetadata,
    ) !Writer {
        const output_path_z = try allocator.dupeZ(u8, output_path);
        errdefer allocator.free(output_path_z);

        const handle = c.archive_write_new() orelse return Error.ArchiveCreateFailed;
        errdefer _ = c.archive_write_free(handle);

        try addFilterForPath(handle, output_path);
        try requireWriteStatus(c.archive_write_set_format_pax_restricted(handle));
        try requireWriteStatus(c.archive_write_open_filename(handle, output_path_z.ptr));

        return .{
            .allocator = allocator,
            .io = io,
            .handle = handle,
            .output_path_z = output_path_z,
            .virtual_metadata = virtual_metadata,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (!self.closed) _ = c.archive_write_close(self.handle);
        _ = c.archive_write_free(self.handle);
        self.allocator.free(self.output_path_z);
        self.* = undefined;
    }

    pub fn addDirectory(self: *Writer, source_directory: []const u8) !void {
        try writeDirectory(
            self.allocator,
            self.io,
            self.handle,
            source_directory,
            null,
            self.virtual_metadata,
        );
    }

    pub fn finish(self: *Writer) !void {
        if (self.closed) return;
        const status = c.archive_write_close(self.handle);
        self.closed = true;
        if (status < c.ARCHIVE_WARN) return Error.ArchiveCloseFailed;
    }
};

/// Writes a gzip-compressed mtree description of `source_directory`. The
/// output itself is excluded so callers may place it inside that directory as
/// `.MTREE`, matching the layout of an Arch package.
pub fn writeMtree(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_directory: []const u8,
    output_path: []const u8,
) !void {
    return writeMtreeWithMetadata(allocator, io, source_directory, output_path, .{});
}

pub fn writeMtreeWithMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_directory: []const u8,
    output_path: []const u8,
    virtual_metadata: VirtualMetadata,
) !void {
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    const handle = c.archive_write_new() orelse return Error.ArchiveCreateFailed;
    defer _ = c.archive_write_free(handle);

    try requireWriteStatus(c.archive_write_add_filter_gzip(handle));
    try requireWriteStatus(c.archive_write_set_format_mtree(handle));
    // BUILDINFO/PKGINFO consumers expect makepkg-style MTREE file hashes.
    // libarchive calculates these from the regular-file data written below.
    try requireWriteStatus(c.archive_write_set_options(handle, "mtree:sha256"));
    try requireWriteStatus(c.archive_write_open_filename(handle, output_path_z.ptr));

    try writeDirectory(allocator, io, handle, source_directory, ".MTREE", virtual_metadata);
    if (c.archive_write_close(handle) < c.ARCHIVE_WARN)
        return Error.ArchiveCloseFailed;
}

fn writeDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    handle: *c.struct_archive,
    source_directory: []const u8,
    skip_path: ?[]const u8,
    virtual_metadata: VirtualMetadata,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, source_directory, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |file_entry| {
        if (skip_path) |skip| {
            if (std.mem.eql(u8, file_entry.path, skip)) continue;
        }

        const stat = try file_entry.dir.statFile(
            io,
            file_entry.basename,
            .{ .follow_symlinks = false },
        );
        if (stat.size > std.math.maxInt(i64)) return Error.EntryTooLarge;

        const archive_entry = c.archive_entry_new() orelse
            return Error.ArchiveEntryCreateFailed;
        defer c.archive_entry_free(archive_entry);
        const archive_path_z = try allocator.dupeZ(u8, file_entry.path);
        defer allocator.free(archive_path_z);

        const file_type: c_uint = switch (file_entry.kind) {
            .file => ae_ifreg,
            .directory => ae_ifdir,
            .sym_link => ae_iflnk,
            else => return Error.UnsupportedFileType,
        };
        setCommonEntryMetadata(
            archive_entry,
            archive_path_z.ptr,
            file_type,
            @intCast(stat.permissions.toMode() & 0o7777),
            virtual_metadata.ownershipForPath(file_entry.path),
        );
        setEntryMtime(archive_entry, stat.mtime.nanoseconds);
        c.archive_entry_set_nlink(archive_entry, @intCast(stat.nlink));

        switch (file_entry.kind) {
            .file => c.archive_entry_set_size(archive_entry, @intCast(stat.size)),
            .sym_link => {
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target_len = try file_entry.dir.readLink(io, file_entry.basename, &target_buffer);
                const target_z = try allocator.dupeZ(u8, target_buffer[0..target_len]);
                defer allocator.free(target_z);
                c.archive_entry_set_symlink(archive_entry, target_z.ptr);
                c.archive_entry_set_size(archive_entry, 0);
            },
            .directory => c.archive_entry_set_size(archive_entry, 0),
            else => unreachable,
        }

        try requireWriteStatus(c.archive_write_header(handle, archive_entry));
        if (file_entry.kind == .file) {
            var file = try file_entry.dir.openFile(io, file_entry.basename, .{});
            defer file.close(io);

            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < stat.size) {
                const remaining: usize = @intCast(@min(stat.size - offset, buffer.len));
                const amount = try file.readPositionalAll(io, buffer[0..remaining], offset);
                if (amount == 0) return Error.ArchiveWriteFailed;
                try writeDataAll(handle, buffer[0..amount]);
                offset += amount;
            }
        }
        try requireWriteStatus(c.archive_write_finish_entry(handle));
    }
}

fn setCommonEntryMetadata(
    entry: *c.struct_archive_entry,
    pathname: [*c]const u8,
    file_type: c_uint,
    permissions: u32,
    ownership: VirtualOwnership,
) void {
    c.archive_entry_set_pathname(entry, pathname);
    c.archive_entry_set_filetype(entry, file_type);
    c.archive_entry_set_perm(entry, @intCast(permissions));
    c.archive_entry_set_uid(entry, ownership.uid);
    c.archive_entry_set_gid(entry, ownership.gid);
    c.archive_entry_set_uname(entry, if (ownership.uid == 0) "root" else null);
    c.archive_entry_set_gname(entry, if (ownership.gid == 0) "root" else null);
}

fn setEntryMtime(entry: *c.struct_archive_entry, nanoseconds: i96) void {
    const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
    const remainder = @mod(nanoseconds, std.time.ns_per_s);
    c.archive_entry_set_mtime(entry, @intCast(seconds), @intCast(remainder));
}

fn writeDataAll(handle: *c.struct_archive, contents: []const u8) !void {
    var offset: usize = 0;
    while (offset < contents.len) {
        const amount = c.archive_write_data(handle, contents[offset..].ptr, contents.len - offset);
        if (amount <= 0) return Error.ArchiveWriteFailed;
        offset += @intCast(amount);
    }
}

fn addFilterForPath(handle: *c.struct_archive, output_path: []const u8) !void {
    const status = if (std.mem.endsWith(u8, output_path, ".zst"))
        c.archive_write_add_filter_zstd(handle)
    else if (std.mem.endsWith(u8, output_path, ".gz"))
        c.archive_write_add_filter_gzip(handle)
    else if (std.mem.endsWith(u8, output_path, ".xz"))
        c.archive_write_add_filter_xz(handle)
    else if (std.mem.endsWith(u8, output_path, ".bz2"))
        c.archive_write_add_filter_bzip2(handle)
    else if (std.mem.endsWith(u8, output_path, ".tar"))
        c.archive_write_add_filter_none(handle)
    else
        return Error.UnsupportedCompression;
    try requireWriteStatus(status);
}

/// Compression of a single source file, rather than an archive of entries.
/// Both the content signature and the source alias must match makepkg's rules.
pub const StandaloneCompression = enum {
    gzip,
    compress,
    bzip2,
    xz,
    zstd,

    pub fn detect(prefix: []const u8) ?StandaloneCompression {
        if (std.mem.startsWith(u8, prefix, "\x1f\x8b")) return .gzip;
        if (std.mem.startsWith(u8, prefix, "\x1f\x9d")) return .compress;
        if (std.mem.startsWith(u8, prefix, "BZh")) return .bzip2;
        if (std.mem.startsWith(u8, prefix, "\xfd7zXZ\x00")) return .xz;
        if (std.mem.startsWith(u8, prefix, "\x28\xb5\x2f\xfd")) return .zstd;
        return null;
    }

    pub fn outputName(self: StandaloneCompression, alias: []const u8) ?[]const u8 {
        const suffixes: []const []const u8 = switch (self) {
            .gzip, .compress => &.{ ".gz", ".z", ".Z" },
            .bzip2 => &.{ ".bz2", ".bz" },
            .xz => &.{".xz"},
            .zstd => &.{".zst"},
        };
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, alias, suffix)) return alias[0 .. alias.len - suffix.len];
        }
        return null;
    }

    pub fn fromFile(io: std.Io, path: []const u8) !?StandaloneCompression {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [16]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var prefix: [6]u8 = undefined;
        const length = try reader.interface.readSliceShort(&prefix);
        return detect(prefix[0..length]);
    }
};

/// A dedicated single-file decoder. Never registers raw format on normal
/// archive readers: raw would otherwise accept ordinary non-archive sources.
pub const CompressedReader = struct {
    raw: ?Reader = null,
    gzip: ?*GzipReader = null,
    empty: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, compression: StandaloneCompression) !CompressedReader {
        if (compression == .gzip) return .{ .gzip = try GzipReader.init(allocator, io, path) };
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        const handle = c.archive_read_new() orelse return Error.ArchiveCreateFailed;
        errdefer _ = c.archive_read_free(handle);
        const expected_filter: c_int = switch (compression) {
            .compress => c.ARCHIVE_FILTER_COMPRESS,
            .bzip2 => c.ARCHIVE_FILTER_BZIP2,
            .xz => c.ARCHIVE_FILTER_XZ,
            .zstd => c.ARCHIVE_FILTER_ZSTD,
            .gzip => unreachable,
        };
        const status = switch (compression) {
            .compress => c.archive_read_support_filter_compress(handle),
            .bzip2 => c.archive_read_support_filter_bzip2(handle),
            .xz => c.archive_read_support_filter_xz(handle),
            .zstd => c.archive_read_support_filter_zstd(handle),
            .gzip => unreachable,
        };
        if (status != c.ARCHIVE_OK or c.archive_read_support_format_raw(handle) != c.ARCHIVE_OK or
            c.archive_read_support_format_empty(handle) != c.ARCHIVE_OK)
            return error.SourceDecompressionFailed;
        if (c.archive_read_open_filename(handle, path_z.ptr, 64 * 1024) != c.ARCHIVE_OK)
            return error.SourceDecompressionFailed;
        if (c.archive_filter_code(handle, 0) != expected_filter or c.archive_filter_count(handle) != 2)
            return error.SourceDecompressionFailed;
        var entry: ?*c.struct_archive_entry = null;
        const header_status = c.archive_read_next_header(handle, &entry);
        if (header_status != c.ARCHIVE_OK and header_status != c.ARCHIVE_EOF)
            return error.SourceDecompressionFailed;
        return .{ .raw = .{ .allocator = allocator, .handle = handle, .path_z = path_z }, .empty = header_status == c.ARCHIVE_EOF };
    }

    pub fn deinit(self: *CompressedReader) void {
        if (self.raw) |*raw| raw.deinit();
        if (self.gzip) |gzip| gzip.deinit();
        self.* = undefined;
    }

    pub fn read(self: *CompressedReader, buffer: []u8) !usize {
        if (self.empty or buffer.len == 0) return 0;
        if (self.gzip) |gzip| return gzip.read(buffer);
        return self.raw.?.read(buffer) catch error.SourceDecompressionFailed;
    }

    /// Bounded streaming copy. The context supplies checkCancelled().
    pub fn copyTo(self: *CompressedReader, writer: *std.Io.Writer, max_bytes: u64, context: anytype) !void {
        var buffer: [64 * 1024]u8 = undefined;
        var remaining = max_bytes;
        while (true) {
            try context.checkCancelled();
            const amount = try self.read(&buffer);
            if (amount == 0) break;
            if (amount > remaining) return error.SourcePayloadTooLarge;
            remaining -= amount;
            try writer.writeAll(buffer[0..amount]);
        }
        try writer.flush();
    }
};

// Libarchive's gzip filter does not validate member CRCs. Zig's streaming
// inflater exposes each member's trailer so we can check its CRC and size.
// Heap storage keeps the reader and inflater's internal pointers stable.
const GzipReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    input_buffer: [64 * 1024]u8 = undefined,
    window: [std.compress.flate.max_window_len]u8 = undefined,
    input: std.Io.File.Reader = undefined,
    inflater: std.compress.flate.Decompress = undefined,
    crc: std.hash.Crc32 = .init(),
    size: u32 = 0,
    done: bool = false,

    fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*GzipReader {
        const self = try allocator.create(GzipReader);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .file = try std.Io.Dir.cwd().openFile(io, path, .{}) };
        self.input = self.file.reader(io, &self.input_buffer);
        self.inflater = .init(&self.input.interface, .gzip, &self.window);
        return self;
    }

    fn deinit(self: *GzipReader) void {
        self.file.close(self.io);
        self.allocator.destroy(self);
    }

    fn read(self: *GzipReader, buffer: []u8) !usize {
        while (!self.done) {
            const amount = self.inflater.reader.readSliceShort(buffer) catch return error.SourceDecompressionFailed;
            if (amount > 0) {
                self.crc.update(buffer[0..amount]);
                self.size +%= @truncate(amount);
                return amount;
            }
            const trailer = self.inflater.container_metadata.gzip;
            if (trailer.crc != self.crc.final() or trailer.count != self.size) return error.SourceDecompressionFailed;
            const next = self.input.interface.peekByte() catch |err| switch (err) {
                error.EndOfStream => {
                    self.done = true;
                    return 0;
                },
                else => return error.SourceDecompressionFailed,
            };
            if (next != 0x1f) return error.SourceDecompressionFailed;
            self.crc = .init();
            self.size = 0;
            self.inflater = .init(&self.input.interface, .gzip, &self.window);
        }
        return 0;
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    handle: *c.struct_archive,
    path_z: [:0]u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Reader {
        return (try initWithSupport(allocator, path, false, false)) orelse
            Error.ArchiveOpenFailed;
    }

    /// Opens a source archive using every filter and format supported by the
    /// installed libarchive. Package readers use init() and remain tar-only.
    pub fn initAll(allocator: std.mem.Allocator, path: []const u8) !Reader {
        return (try initWithSupport(allocator, path, true, false)) orelse
            Error.ArchiveOpenFailed;
    }

    /// Opens a source only when libarchive recognizes its contents. A null
    /// result means no registered format bidder accepted the readable input.
    pub fn initAllIfRecognized(allocator: std.mem.Allocator, path: []const u8) !?Reader {
        return initWithSupport(allocator, path, true, true);
    }

    fn initWithSupport(
        allocator: std.mem.Allocator,
        path: []const u8,
        support_all: bool,
        allow_unrecognized: bool,
    ) !?Reader {
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);

        const handle = c.archive_read_new() orelse return Error.ArchiveCreateFailed;
        errdefer _ = c.archive_read_free(handle);

        if (support_all) {
            try requireStatus(c.archive_read_support_filter_all(handle));
            try requireStatus(c.archive_read_support_format_all(handle));
        } else {
            try requireStatus(c.archive_read_support_filter_none(handle));
            try requireStatus(c.archive_read_support_filter_gzip(handle));
            try requireStatus(c.archive_read_support_filter_zstd(handle));
            try requireStatus(c.archive_read_support_format_tar(handle));
        }

        if (c.archive_read_open_filename(handle, path_z.ptr, 64 * 1024) < c.ARCHIVE_WARN) {
            if (allow_unrecognized and c.archive_format(handle) == 0) {
                _ = c.archive_read_free(handle);
                allocator.free(path_z);
                return null;
            }
            return Error.ArchiveOpenFailed;
        }

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

    /// Mtree's permissive text bidder also accepts ordinary compressed text.
    /// Empty decompressed streams likewise describe a file, not an archive.
    pub fn isCompressedPlainFile(self: *Reader) bool {
        const format = c.archive_format(self.handle);
        return c.archive_filter_count(self.handle) > 1 and
            (format == c.ARCHIVE_FORMAT_MTREE or format == c.ARCHIVE_FORMAT_EMPTY);
    }

    /// Result of asking libarchive's registered format bidders to classify
    /// the input. The first entry is returned with the open reader so callers
    /// can continue extracting without reopening the untrusted source.
    pub const Probe = union(enum) {
        not_archive,
        archive: ?Entry,
    };

    pub fn probe(self: *Reader) !Probe {
        var raw_entry: ?*c.struct_archive_entry = null;
        const status = c.archive_read_next_header(self.handle, &raw_entry);
        if (status == c.ARCHIVE_EOF)
            return if (c.archive_format(self.handle) == 0)
                .not_archive
            else
                .{ .archive = null };
        if (status < c.ARCHIVE_WARN)
            return if (c.archive_format(self.handle) == 0)
                .not_archive
            else
                Error.ArchiveReadFailed;
        const entry = raw_entry orelse return Error.ArchiveReadFailed;
        return .{ .archive = try entryFromRaw(entry) };
    }

    pub fn next(self: *Reader) !?Entry {
        var raw_entry: ?*c.struct_archive_entry = null;
        const status = c.archive_read_next_header(self.handle, &raw_entry);
        if (status == c.ARCHIVE_EOF) return null;
        if (status < c.ARCHIVE_WARN or raw_entry == null) return Error.ArchiveReadFailed;

        return @as(?Entry, try entryFromRaw(raw_entry.?));
    }

    fn entryFromRaw(entry: *c.struct_archive_entry) !Entry {
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
            .uid = @intCast(c.archive_entry_uid(entry)),
            .gid = @intCast(c.archive_entry_gid(entry)),
            .mtime = try entryMtime(entry),
            .link_target = if (c.archive_entry_symlink_utf8(entry)) |target|
                std.mem.span(target)
            else if (c.archive_entry_symlink(entry)) |target|
                std.mem.span(target)
            else
                null,
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

fn entryMtime(entry: *c.struct_archive_entry) !?std.Io.Timestamp {
    if (c.archive_entry_mtime_is_set(entry) == 0) return null;
    const nanoseconds = c.archive_entry_mtime_nsec(entry);
    if (nanoseconds < 0 or nanoseconds >= std.time.ns_per_s)
        return Error.InvalidEntryTimestamp;
    const seconds: i96 = @intCast(c.archive_entry_mtime(entry));
    return .{ .nanoseconds = seconds * std.time.ns_per_s + @as(i96, @intCast(nanoseconds)) };
}

fn requireStatus(status: c_int) !void {
    if (status < c.ARCHIVE_WARN) return Error.ArchiveReadFailed;
}

fn requireWriteStatus(status: c_int) !void {
    if (status < c.ARCHIVE_WARN) return Error.ArchiveWriteFailed;
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
// than making tests depend on external `tar`, `gzip`, `zstd`, or `xz` executables.
pub const FixtureCompression = enum { none, gzip, zstd, xz, bzip2, compress };

pub const FixtureEntry = struct {
    path: [:0]const u8,
    kind: EntryKind = .regular_file,
    contents: []const u8 = "",
    permissions: u32 = 0o644,
    link_target: ?[:0]const u8 = null,
    mtime: ?std.Io.Timestamp = null,
};

pub fn writeFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
    compression: FixtureCompression,
    entries: []const FixtureEntry,
) !void {
    return writeFixtureWithFormat(allocator, path, compression, .pax, entries);
}

pub fn writeZipFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: []const FixtureEntry,
) !void {
    return writeFixtureWithFormat(allocator, path, .none, .zip, entries);
}

pub fn writeCompressedFixture(allocator: std.mem.Allocator, path: []const u8, compression: FixtureCompression, contents: []const u8) !void {
    return writeFixtureWithFormat(allocator, path, compression, .raw, &.{.{ .path = "embedded-name", .contents = contents }});
}

const FixtureFormat = enum { pax, zip, raw };

fn writeFixtureWithFormat(
    allocator: std.mem.Allocator,
    path: []const u8,
    compression: FixtureCompression,
    format: FixtureFormat,
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
        .xz => c.archive_write_add_filter_xz(handle),
        .bzip2 => c.archive_write_add_filter_bzip2(handle),
        .compress => c.archive_write_add_filter_compress(handle),
    };
    if (filter_status < c.ARCHIVE_WARN) return Error.ArchiveWriteFailed;
    const needs_full_pax = for (entries) |fixture| {
        const mtime = fixture.mtime orelse continue;
        if (@mod(mtime.nanoseconds, std.time.ns_per_s) != 0) break true;
    } else false;
    const format_status = switch (format) {
        .pax => if (needs_full_pax)
            c.archive_write_set_format_pax(handle)
        else
            c.archive_write_set_format_pax_restricted(handle),
        .zip => c.archive_write_set_format_zip(handle),
        .raw => c.archive_write_set_format_raw(handle),
    };
    if (format_status < c.ARCHIVE_WARN)
        return Error.ArchiveWriteFailed;
    if (c.archive_write_open_filename(handle, path_z.ptr) < c.ARCHIVE_WARN)
        return Error.ArchiveWriteFailed;
    defer _ = c.archive_write_close(handle);

    for (entries) |fixture| {
        const entry = c.archive_entry_new() orelse return Error.ArchiveCreateFailed;
        defer c.archive_entry_free(entry);
        const kind: EntryKind = if (fixture.link_target != null) .symbolic_link else fixture.kind;
        c.archive_entry_set_pathname(entry, fixture.path.ptr);
        c.archive_entry_set_filetype(entry, switch (kind) {
            .regular_file => ae_ifreg,
            .directory => ae_ifdir,
            .symbolic_link => ae_iflnk,
            .other => return Error.UnsupportedFileType,
        });
        c.archive_entry_set_perm(entry, @intCast(fixture.permissions));
        c.archive_entry_set_size(entry, if (kind == .regular_file) @intCast(fixture.contents.len) else 0);
        if (kind == .symbolic_link) {
            const target = fixture.link_target orelse return Error.ArchiveWriteFailed;
            c.archive_entry_set_symlink(entry, target.ptr);
        }
        if (fixture.mtime) |mtime| setEntryMtime(entry, mtime.nanoseconds);
        if (c.archive_write_header(handle, entry) < c.ARCHIVE_WARN)
            return Error.ArchiveWriteFailed;
        if (kind == .regular_file and fixture.contents.len != 0) {
            const amount = c.archive_write_data(handle, fixture.contents.ptr, fixture.contents.len);
            if (amount < 0 or amount != fixture.contents.len) return Error.ArchiveWriteFailed;
        }
    }
}

test "archive reader exposes exact entry modification timestamps" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/timestamp.tar",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(path);
    const expected: std.Io.Timestamp = .{ .nanoseconds = 1_234_567_890_123_456_789 };
    try writeFixture(testing.allocator, path, .none, &.{
        .{ .path = "timestamped", .contents = "payload", .mtime = expected },
    });

    var reader = try Reader.initAll(testing.allocator, path);
    defer reader.deinit();
    const entry = (try reader.next()).?;
    try testing.expectEqual(expected.nanoseconds, entry.mtime.?.nanoseconds);
}

test "archive writer preserves tree modes and symlinks while forcing root ownership" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "tree/bin");
    try tmp.dir.writeFile(io, .{
        .sub_path = "tree/bin/demo",
        .data = "payload",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    try tmp.dir.symLink(io, "demo", "tree/bin/demo-link", .{});

    const source_path = try tmp.dir.realPathFileAlloc(io, "tree", testing.allocator);
    defer testing.allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/writer.pkg.tar.zst",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(output_path);

    var writer = try Writer.init(testing.allocator, io, output_path);
    defer writer.deinit();
    try writer.addDirectory(source_path);
    try writer.finish();

    var reader = try Reader.init(testing.allocator, output_path);
    defer reader.deinit();
    var saw_file = false;
    var saw_link = false;
    while (try reader.next()) |entry| {
        try testing.expectEqual(@as(i64, 0), entry.uid);
        try testing.expectEqual(@as(i64, 0), entry.gid);
        if (std.mem.eql(u8, entry.path, "bin/demo")) {
            saw_file = true;
            try testing.expectEqual(EntryKind.regular_file, entry.kind);
            try testing.expectEqual(@as(u32, 0o755), entry.permissions);
            var contents: [7]u8 = undefined;
            try testing.expectEqual(contents.len, try reader.readPrefix(&contents));
            try testing.expectEqualStrings("payload", &contents);
        } else if (std.mem.eql(u8, entry.path, "bin/demo-link")) {
            saw_link = true;
            try testing.expectEqual(EntryKind.symbolic_link, entry.kind);
            try testing.expectEqualStrings("demo", entry.link_target.?);
        }
    }
    try testing.expect(saw_file);
    try testing.expect(saw_link);
}

test "archive virtual ownership is shared by package and mtree writers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "tree/usr/share/demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/usr/share/demo/data", .data = "payload" });
    const source_path = try tmp.dir.realPathFileAlloc(io, "tree", testing.allocator);
    defer testing.allocator.free(source_path);
    const package_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/virtual.pkg.tar.zst",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(package_path);
    const mtree_path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/virtual.mtree.gz",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(mtree_path);

    const overrides = [_]OwnershipOverride{.{
        .path = "usr/share/demo/data",
        .ownership = .{ .uid = 42, .gid = 84 },
    }};
    const metadata: VirtualMetadata = .{ .ownership_overrides = &overrides };
    var writer = try Writer.initWithMetadata(testing.allocator, io, package_path, metadata);
    defer writer.deinit();
    try writer.addDirectory(source_path);
    try writer.finish();
    try writeMtreeWithMetadata(testing.allocator, io, source_path, mtree_path, metadata);

    inline for (.{ package_path, mtree_path }) |path| {
        var reader = try Reader.initAll(testing.allocator, path);
        defer reader.deinit();
        var saw_data = false;
        while (try reader.next()) |entry| {
            if (!std.mem.eql(u8, entry.path, "usr/share/demo/data")) continue;
            saw_data = true;
            try testing.expectEqual(@as(i64, 42), entry.uid);
            try testing.expectEqual(@as(i64, 84), entry.gid);
        }
        try testing.expect(saw_data);
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

const CompressionTestContext = struct {
    calls: usize = 0,
    cancel_after: usize = std.math.maxInt(usize),
    pub fn checkCancelled(self: *@This()) !void {
        if (self.calls >= self.cancel_after) return error.Cancelled;
        self.calls += 1;
    }
};

test "standalone compression streams every supported format including empty files" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/payload", .{tmp.sub_path});
    defer testing.allocator.free(path);
    inline for (.{ FixtureCompression.gzip, .compress, .bzip2, .xz, .zstd }) |compression| {
        for ([_][]const u8{ "payload\n", "" }) |contents| {
            try writeCompressedFixture(testing.allocator, path, compression, contents);
            // Libarchive's compress writer emits a spurious zero code for empty input.
            if (compression == .compress and contents.len == 0)
                try tmp.dir.writeFile(testing.io, .{ .sub_path = "payload", .data = "\x1f\x9d\x90" });
            const detected = (try StandaloneCompression.fromFile(testing.io, path)).?;
            try testing.expectEqualStrings(@tagName(compression), @tagName(detected));
            var reader = try CompressedReader.init(testing.allocator, testing.io, path, detected);
            defer reader.deinit();
            var output: std.Io.Writer.Allocating = .init(testing.allocator);
            defer output.deinit();
            var context: CompressionTestContext = .{};
            reader.copyTo(&output.writer, contents.len, &context) catch |err| {
                std.debug.print("compression={s} length={d}\n", .{ @tagName(compression), contents.len });
                return err;
            };
            try testing.expectEqualStrings(contents, output.written());
        }
    }
}

test "standalone compression enforces output limits and cancellation while streaming" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/payload", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const contents = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(contents);
    @memset(contents, 'a');
    try writeCompressedFixture(testing.allocator, path, .gzip, contents);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: CompressionTestContext = .{};
    var reader = try CompressedReader.init(testing.allocator, testing.io, path, .gzip);
    defer reader.deinit();
    try testing.expectError(error.SourcePayloadTooLarge, reader.copyTo(&output.writer, 65536, &context));
    try testing.expectEqual(@as(usize, 65536), output.written().len);
    var cancelled_reader = try CompressedReader.init(testing.allocator, testing.io, path, .gzip);
    defer cancelled_reader.deinit();
    context = .{ .cancel_after = 1 };
    try testing.expectError(error.Cancelled, cancelled_reader.copyTo(&output.writer, contents.len, &context));
}

test "standalone compression validates concatenated gzip members and trailers" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/payload", .{tmp.sub_path});
    defer testing.allocator.free(path);
    try writeCompressedFixture(testing.allocator, path, .gzip, "payload\n");
    const compressed = try tmp.dir.readFileAlloc(testing.io, "payload", testing.allocator, .limited(1024));
    defer testing.allocator.free(compressed);
    const concatenated = try std.mem.concat(testing.allocator, u8, &.{ compressed, compressed });
    defer testing.allocator.free(concatenated);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "payload", .data = concatenated });
    var reader = try CompressedReader.init(testing.allocator, testing.io, path, .gzip);
    defer reader.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: CompressionTestContext = .{};
    try reader.copyTo(&output.writer, 16, &context);
    try testing.expectEqualStrings("payload\npayload\n", output.written());
    for ([_]usize{ 0, 4 }) |truncate| {
        compressed[compressed.len - 8] ^= 1;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "payload", .data = compressed[0 .. compressed.len - truncate] });
        var damaged = try CompressedReader.init(testing.allocator, testing.io, path, .gzip);
        defer damaged.deinit();
        try testing.expectError(error.SourceDecompressionFailed, damaged.copyTo(&output.writer, 1024, &context));
    }
}
