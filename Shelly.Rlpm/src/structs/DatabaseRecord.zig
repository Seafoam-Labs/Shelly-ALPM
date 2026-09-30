//! Database readers use libalpm's permissive scalar rules; the public standalone
//! ParsedDescription parser remains strict. All strings here borrow the input.
const std = @import("std");
const Parsed = @import("ParsedDescription.zig");
const Backup = @import("BackupFile.zig");

pub const Issues = packed struct {
    identity_mismatch: bool = false,
    invalid_size: bool = false,
    invalid_date: bool = false,
};

pub const Identity = struct {
    name: []const u8,
    version: []const u8,
};

pub fn splitName(path: []const u8) !Identity {
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const entry = path[0..end];
    const release = std.mem.lastIndexOfScalar(u8, entry, '-') orelse return error.InvalidDatabaseEntry;
    const version = std.mem.lastIndexOfScalar(u8, entry[0..release], '-') orelse
        return error.InvalidDatabaseEntry;
    if (version == 0) return error.InvalidDatabaseEntry;
    return .{ .name = entry[0..version], .version = entry[version + 1 ..] };
}

pub fn append(
    parsed: *Parsed,
    allocator: std.mem.Allocator,
    contents: []const u8,
    sync: bool,
    issues: *Issues,
) !void {
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return error.InvalidDatabaseEntry;
    // libarchive's line reader supplies an empty last line after a terminal
    // newline, so that newline can terminate the final list, as captured by the
    // database reference fixtures.
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const header = std.mem.trimEnd(u8, raw, "\r");
        if (header.len == 0) continue;
        if (header.len > 512 * 1024) return error.MetadataLineTooLong;
        var section = Parsed.descSectionFromHeader(header);
        if (sync) {
            switch (section) {
                .installed_database, .install_date, .reason, .validation, .backups => section = .ignore,
                else => {},
            }
            if (std.mem.eql(u8, header, "%XDATA%") or std.mem.eql(u8, header, "%SIZE%")) section = .ignore;
        } else {
            switch (section) {
                .repository_filename,
                .compressed_size,
                .md5_sum,
                .sha256_sum,
                .base64_signature,
                => section = .ignore,
                else => {},
            }
            if (std.mem.eql(u8, header, "%DATA%") or std.mem.eql(u8, header, "%ISIZE%")) section = .ignore;
        }
        const multiple = switch (section) {
            .ignore,
            .none,
            .files,
            .backups,
            .groups,
            .licenses,
            .depends,
            .optional_depends,
            .make_depends,
            .check_depends,
            .conflicts,
            .provides,
            .replaces,
            .xdata,
            .validation,
            => true,
            else => false,
        };
        if (section == .files) {
            parsed.files_loaded = true;
            parsed.files.clearRetainingCapacity();
        }
        while (true) {
            const value = std.mem.trimEnd(u8, lines.next() orelse {
                if (sync) return error.InvalidDatabaseEntry;
                break;
            }, "\r");
            if (value.len > 512 * 1024) return error.MetadataLineTooLong;
            if (multiple and value.len == 0) break;
            try apply(parsed, allocator, section, value, issues);
            if (!multiple) break;
        }
    }
}

pub fn apply(
    parsed: *Parsed,
    allocator: std.mem.Allocator,
    section: Parsed.DescSection,
    value: []const u8,
    issues: *Issues,
) !void {
    switch (section) {
        .name, .version => {
            const identity = if (section == .name) parsed.name else parsed.version;
            if (identity) |expected|
                if (!std.mem.eql(u8, expected, value)) {
                    issues.identity_mismatch = true;
                };
        },
        inline .base,
        .description,
        .url,
        .architecture,
        .packager,
        .installed_database,
        .repository_filename,
        .md5_sum,
        .sha256_sum,
        .base64_signature,
        => |tag| @field(parsed, @tagName(tag)) = value,
        inline .compressed_size, .installed_size => |tag| {
            // A negative/error off_t has no unsigned size. Preserve the package
            // with an unavailable size and an explicit issue instead of wrapping.
            @field(parsed, @tagName(tag)) = if (value.len == 0 or !std.ascii.isDigit(value[0]))
                null
            else
                std.fmt.parseInt(u64, value, 10) catch null;
            if (@field(parsed, @tagName(tag))) |size| {
                if (size > std.math.maxInt(i64)) @field(parsed, @tagName(tag)) = null;
            }
            if (@field(parsed, @tagName(tag)) == null) issues.invalid_size = true;
        },
        inline .build_date, .install_date => |tag| {
            @field(parsed, @tagName(tag)) = std.fmt.parseInt(
                i64,
                std.mem.trimStart(
                    u8,
                    value,
                    " \t\r\n\x0b\x0c",
                ),
                10,
            ) catch blk: {
                issues.invalid_date = true;
                break :blk 0;
            };
        },
        .reason => parsed.reason = if (std.mem.eql(u8, value, "0"))
            .explicit
        else if (std.mem.eql(u8, value, "1"))
            .dependency
        else
            .unknown,
        .validation => {
            inline for (.{ "none", "md5", "sha256", "pgp" }) |field|
                if (std.mem.eql(u8, value, field)) {
                    @field(parsed.validation, field) = true;
                };
        },
        .files => try parsed.files.append(
            allocator,
            .{
                .name = value,
                .kind = if (std.mem.endsWith(u8, value, "/"))
                    .directory
                else
                    .unknown,
            },
        ),
        .backups => try parsed.backups.append(allocator, try Backup.parseLocal(value)),
        inline .groups,
        .licenses,
        .depends,
        .optional_depends,
        .make_depends,
        .check_depends,
        .conflicts,
        .provides,
        .replaces,
        => |tag| try @field(parsed, @tagName(tag)).append(
            allocator,
            value,
        ),
        .xdata => {
            const index = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidXData;
            if (index == 0) return error.InvalidXData;
            try parsed.xdata.append(allocator, .{ .name = value[0..index], .value = value[index + 1 ..] });
        },
        .none, .ignore => {},
    }
}

pub fn validateFilename(name: []const u8) !void {
    if (name.len > 4096 or (name.len > 0 and name[0] == '.') or std.mem.indexOfAny(u8, name, "/\x00") != null)
        return error.InvalidPackageFilename;
}
