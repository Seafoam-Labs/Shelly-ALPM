//! Archive traversal never extracts member paths. CachyOS SQLite is deserialized
//! read-only in memory and normalized into the same records as tar repositories.
const std = @import("std");
const Database = @import("Database.zig");
const Archive = @import("ArchiveReader.zig");
const Parsed = @import("ParsedDescription.zig");
const Record = @import("DatabaseRecord.zig");
const Package = @import("Package.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Format = enum { unknown, tar, sqlite, mixed };
format: Format = .unknown,

const Entry = struct {
    parsed: Parsed,
    issues: Record.Issues = .{},
};
const Records = std.StringArrayHashMapUnmanaged(Entry);

pub fn populate(io: std.Io, db: *Database) !void {
    // Preserve filesystem errors (libarchive itself coalesces many errors).
    const file = try std.Io.Dir.cwd().openFile(io, db.path, .{});
    file.close(io);
    try populateFromPath(db, db.path);
}

/// Internal candidate loading; Database passes a verified immutable snapshot.
pub fn populateFromPath(db: *Database, path: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(db.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var reader = try Archive.openFile(allocator, path);
    defer reader.deinit();
    var records: Records = .{};
    var tar = false;
    var sqlite = false;
    while (try reader.next()) |member| {
        if (member.kind == .directory) continue;
        const name = Archive.normalizedName(member.name);
        if (member.kind != .regular) return error.InvalidDatabaseEntry;
        if (std.mem.eql(u8, name, "pacman.db")) {
            const bytes = try reader.readAll(allocator, 512 << 20);
            try readSqlite(allocator, bytes, &records);
            sqlite = true;
            continue;
        }
        tar = true;
        const identity = try Record.splitName(name);
        const result = try records.getOrPut(allocator, identity.name);
        if (!result.found_existing) {
            const owned_name = try allocator.dupe(u8, identity.name);
            result.key_ptr.* = owned_name;
            result.value_ptr.* = .{
                .parsed = .{
                    .name = owned_name,
                    .version = try allocator.dupe(u8, identity.version),
                },
            };
            try validateIdentity(result.value_ptr.parsed);
        }
        const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse continue;
        const filename = name[slash + 1 ..];
        if (!std.mem.eql(u8, filename, "desc") and !std.mem.eql(u8, filename, "depends") and
            !std.mem.eql(u8, filename, "files"))
            continue;
        const bytes = try reader.readAll(allocator, 32 << 20);
        try Record.append(&result.value_ptr.parsed, allocator, bytes, true, &result.value_ptr.issues);
        if (result.value_ptr.parsed.repository_filename) |value| try Record.validateFilename(value);
    }
    try reader.finish();
    for (records.values()) |entry| {
        var package = try entry.parsed.intoPackage(
            &db.cache_arena,
            .{
                .origin = .sync,
                .database_name = db.name,
            },
        );
        package.metadata_issues = entry.issues;
        package.validation = .{ .none = true };
        try db.addPackage(package);
    }
    db.backend.sync.format = if (tar and sqlite) .mixed else if (sqlite) .sqlite else .tar;
}

fn validateIdentity(parsed: Parsed) !void {
    const name = parsed.name orelse return error.InvalidDatabaseEntry;
    const version = parsed.version orelse return error.InvalidDatabaseEntry;
    if (name.len + version.len + 1 > 255) return error.InvalidDatabaseEntry;
    if (name.len == 0 or name[0] == '.' or name[0] == '-' or
        std.mem.indexOfAny(u8, name, "/\x00 \t\r\n") != null)
        return error.InvalidDatabaseEntry;
    for (name) |byte|
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "@._+-", byte) == null)
            return error.InvalidDatabaseEntry;
    const dash = std.mem.indexOfScalar(u8, version, '-') orelse return error.InvalidDatabaseEntry;
    if (std.mem.indexOfAny(u8, version, "/\x00") != null or
        std.mem.indexOfScalar(
            u8,
            version[dash + 1 ..],
            '-',
        ) != null)
        return error.InvalidDatabaseEntry;
}

fn check(code: c_int) !void {
    if (code == c.SQLITE_NOMEM) return error.OutOfMemory;
    if (code != c.SQLITE_OK) return error.InvalidSqliteDatabase;
}

fn readSqlite(allocator: std.mem.Allocator, bytes: []u8, records: *Records) !void {
    var handle: ?*c.sqlite3 = null;
    const opened = c.sqlite3_open_v2(
        ":memory:",
        &handle,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
        null,
    );
    defer if (handle) |db| {
        _ = c.sqlite3_close(db);
    };
    try check(opened);
    const size = std.math.cast(i64, bytes.len) orelse return error.MetadataTooLarge;
    try check(c.sqlite3_deserialize(handle, "main", bytes.ptr, size, size, c.SQLITE_DESERIALIZE_READONLY));
    try check(c.sqlite3_exec(handle, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;", null, null, null));
    // Only an ordinary packages table is accepted, not schema-supplied views.
    var schema: ?*c.sqlite3_stmt = null;
    try check(
        c.sqlite3_prepare_v2(
            handle,
            "SELECT type FROM sqlite_schema WHERE name='packages' COLLATE NOCASE",
            -1,
            &schema,
            null,
        ),
    );
    defer _ = c.sqlite3_finalize(schema);
    const schema_status = c.sqlite3_step(schema);
    if (schema_status == c.SQLITE_NOMEM) return error.OutOfMemory;
    if (schema_status != c.SQLITE_ROW) return error.InvalidSqliteDatabase;
    const kind = c.sqlite3_column_text(schema, 0);
    if (kind == null or !std.mem.eql(u8, std.mem.span(kind), "table"))
        return error.InvalidSqliteDatabase;
    var statement: ?*c.sqlite3_stmt = null;
    try check(c.sqlite3_prepare_v2(handle, "SELECT * FROM packages", -1, &statement, null));
    defer _ = c.sqlite3_finalize(statement);
    const columns = c.sqlite3_column_count(statement);
    var has_name = false;
    var has_version = false;
    for (0..@intCast(columns)) |index| {
        const column_name = c.sqlite3_column_name(statement, @intCast(index));
        if (column_name == null) return error.OutOfMemory;
        const column = std.mem.span(column_name);
        has_name = has_name or std.mem.eql(u8, column, "name");
        has_version = has_version or std.mem.eql(u8, column, "version");
    }
    if (!has_name or !has_version) return error.InvalidSqliteDatabase;
    while (true) {
        const status = c.sqlite3_step(statement);
        if (status == c.SQLITE_DONE) break;
        if (status != c.SQLITE_ROW) {
            try check(status);
            unreachable;
        }
        var entry: Entry = .{ .parsed = .{} };
        for (0..@intCast(columns)) |index| {
            const column_index: c_int = @intCast(index);
            if (c.sqlite3_column_type(statement, column_index) == c.SQLITE_NULL) continue;
            const column_name = c.sqlite3_column_name(statement, column_index);
            if (column_name == null) return error.OutOfMemory;
            const column = std.mem.span(column_name);
            const text = c.sqlite3_column_text(statement, column_index) orelse return error.OutOfMemory;
            const value = try allocator.dupe(
                u8,
                text[0..@intCast(c.sqlite3_column_bytes(
                    statement,
                    column_index,
                ))],
            );
            if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidDatabaseEntry;
            if (std.mem.eql(u8, column, "name")) {
                entry.parsed.name = value;
                continue;
            }
            if (std.mem.eql(u8, column, "version")) {
                entry.parsed.version = value;
                continue;
            }
            const section = sqlSection(column);
            switch (section) {
                .groups,
                .licenses,
                .depends,
                .optional_depends,
                .make_depends,
                .check_depends,
                .conflicts,
                .provides,
                .replaces,
                .files,
                => {
                    if (section == .files) entry.parsed.files_loaded = true;
                    var items = std.mem.tokenizeScalar(u8, value, ',');
                    while (items.next()) |item|
                        try Record.apply(
                            &entry.parsed,
                            allocator,
                            section,
                            item,
                            &entry.issues,
                        );
                },
                else => try Record.apply(&entry.parsed, allocator, section, value, &entry.issues),
            }
        }
        try validateIdentity(entry.parsed);
        if (entry.parsed.repository_filename) |value| try Record.validateFilename(value);
        if (records.contains(entry.parsed.name.?)) return error.DuplicatePackage;
        try records.put(allocator, entry.parsed.name.?, entry);
    }
}

fn sqlSection(column: []const u8) Parsed.DescSection {
    // Exactly the column names implemented by the pinned CachyOS backend.
    const mapping = .{
        .{ "filename", .repository_filename },
        .{ "base", .base },
        .{ "desc", .description },
        .{ "groups", .groups },
        .{ "url", .url },
        .{ "license", .licenses },
        .{ "arch", .architecture },
        .{ "builddate", .build_date },
        .{ "packager", .packager },
        .{ "csize", .compressed_size },
        .{ "isize", .installed_size },
        .{ "sha256sum", .sha256_sum },
        .{ "pgpsig", .base64_signature },
        .{ "replaces", .replaces },
        .{ "depends", .depends },
        .{ "optdepends", .optional_depends },
        .{ "makedepends", .make_depends },
        .{ "checkdepends", .check_depends },
        .{ "conflicts", .conflicts },
        .{ "provides", .provides },
        .{ "files", .files },
    };
    inline for (mapping) |pair|
        if (std.mem.eql(u8, column, pair[0])) return pair[1];
    return .ignore;
}
