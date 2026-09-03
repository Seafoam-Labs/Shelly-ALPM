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
pub const FixtureCompression = enum { none, gzip, zstd, xz };

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

const FixtureFormat = enum { pax, zip };

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
