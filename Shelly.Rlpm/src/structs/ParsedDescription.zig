//! Parsed strings borrow their input. Conversion deep-copies into an explicit
//! enclosing arena; releasing that arena reclaims complete or failed conversions.
const std = @import("std");
const Package = @import("Package.zig");
const PackageRelation = @import("PackageRelation.zig");
const Version = @import("Version.zig");
const PackageFile = @import("PackageFile.zig");
const BackupFile = @import("BackupFile.zig");

const ParsedDescription = @This();

name: ?[]const u8 = null,
version: ?[]const u8 = null,
base: ?[]const u8 = null,
description: ?[]const u8 = null,
url: ?[]const u8 = null,
architecture: ?[]const u8 = null,
build_date: ?i64 = null,
install_date: ?i64 = null,
packager: ?[]const u8 = null,
installed_size: ?u64 = null,
compressed_size: ?u64 = null,
repository_filename: ?[]const u8 = null,
md5_sum: ?[]const u8 = null,
sha256_sum: ?[]const u8 = null,
base64_signature: ?[]const u8 = null,
installed_database: ?[]const u8 = null,
reason: ?Package.InstallReason = null,
validation: Package.Validation = .{},

groups: std.ArrayList([]const u8) = .empty,
licenses: std.ArrayList([]const u8) = .empty,
depends: std.ArrayList([]const u8) = .empty,
optional_depends: std.ArrayList([]const u8) = .empty,
make_depends: std.ArrayList([]const u8) = .empty,
check_depends: std.ArrayList([]const u8) = .empty,
conflicts: std.ArrayList([]const u8) = .empty,
provides: std.ArrayList([]const u8) = .empty,
replaces: std.ArrayList([]const u8) = .empty,
xdata: std.ArrayList(Package.XData) = .empty,

files: std.ArrayList(PackageFile) = .empty,
backups: std.ArrayList(BackupFile) = .empty,
files_loaded: bool = false,

/// The arena owns all result fields, including copied input strings. Failed
/// conversion retains only arena allocations, reclaimed with the enclosing arena.
/// The parsed input is unchanged, so callers may retry or convert multiple times.
pub fn intoPackage(
    self: *const ParsedDescription,
    arena: *std.heap.ArenaAllocator,
    source: Package.Source,
) !Package {
    const allocator = arena.allocator();
    const name = self.name orelse return error.MissingPackageName;
    const raw_version = self.version orelse return error.MissingPackageVersion;
    if (name.len == 0) return error.MissingPackageName;
    if (raw_version.len == 0) return error.InvalidVersion;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidPackageName;
    var result: Package = .{
        .name = try allocator.dupe(u8, name),
        .version = try Version.initRaw(raw_version, allocator),
        .origin = source.origin,
        .database_name = try allocator.dupe(u8, source.database_name),
        .archive_path = try copyOptional(allocator, source.archive_path),
        .metadata_directory = try copyOptional(allocator, source.metadata_directory),
        .install_reason = self.reason orelse .explicit,
        .validation = self.validation,
        .build_date = self.build_date,
        .install_date = self.install_date,
        .installed_size = self.installed_size,
        .compressed_size = self.compressed_size,
        .files_loaded = self.files_loaded,
        .files_source = if (self.files_loaded) .database else .none,
        .download_size = if (source.origin == .archive or source.origin == .local) 0 else null,
    };
    inline for (.{
        "base",
        "description",
        "url",
        "architecture",
        "packager",
        "installed_database",
        "repository_filename",
        "md5_sum",
        "sha256_sum",
        "base64_signature",
    }) |field| {
        @field(result, field) = try copyOptional(allocator, @field(self, field));
    }
    inline for (.{
        "depends",
        "optional_depends",
        "make_depends",
        "check_depends",
        "provides",
        "conflicts",
        "replaces",
    }) |field| {
        const values = @field(self, field).items;
        const relations = try allocator.alloc(PackageRelation, values.len);
        for (values, relations) |value, *relation|
            relation.* = try (try PackageRelation.parse(value)).clone(
                allocator,
            );
        @field(result, field) = relations;
    }
    inline for (.{ "groups", "licenses" }) |field| {
        const values = @field(self, field).items;
        const strings = try allocator.alloc([]const u8, values.len);
        for (values, strings) |value, *string|
            string.* = try allocator.dupe(u8, value);
        @field(result, field) = strings;
    }
    const xdata = try allocator.alloc(Package.XData, self.xdata.items.len);
    for (self.xdata.items, xdata) |item, *owned|
        owned.* = .{
            .name = try allocator.dupe(u8, item.name),
            .value = try allocator.dupe(u8, item.value),
        };
    result.xdata = xdata;
    const files = try allocator.alloc(PackageFile, self.files.items.len);
    for (self.files.items, files) |item, *owned| {
        owned.* = item;
        owned.name = try allocator.dupe(u8, item.name);
        owned.link_target = try copyOptional(allocator, item.link_target);
    }
    std.mem.sort(PackageFile, files, {}, struct {
        fn less(_: void, a: PackageFile, b: PackageFile) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    result.files = files;
    const backups = try allocator.alloc(BackupFile, self.backups.items.len);
    for (self.backups.items, backups) |item, *owned|
        owned.* = .{
            .name = try allocator.dupe(u8, item.name),
            .hash = try copyOptional(allocator, item.hash),
        };
    result.backups = backups;
    return result;
}

fn copyOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

/// Frees parser list storage only. Input buffers and converted packages are independent.
pub fn deinit(self: *ParsedDescription, allocator: std.mem.Allocator) void {
    inline for (.{
        "groups",
        "licenses",
        "depends",
        "optional_depends",
        "make_depends",
        "check_depends",
        "provides",
        "conflicts",
        "replaces",
        "xdata",
        "files",
        "backups",
    }) |field|
        @field(self, field).deinit(allocator);
    self.* = undefined;
}

pub fn parse(
    allocator: std.mem.Allocator,
    contents: []const u8,
) !ParsedDescription {
    var result: ParsedDescription = .{};
    errdefer result.deinit(allocator);

    var section: DescSection = .none;
    var lines = std.mem.splitScalar(u8, contents, '\n');

    while (lines.next()) |raw_line| {
        // Handle files containing Windows-style CRLF line endings.
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        // A blank line terminates the current section.
        if (line.len == 0) {
            section = .none;
            continue;
        }

        // Section header, such as "%DEPENDS%".
        if (line.len >= 2 and
            line[0] == '%' and
            line[line.len - 1] == '%')
        {
            section = descSectionFromHeader(line);
            if (section == .files) result.files_loaded = true;
            continue;
        }

        switch (section) {
            .none => return error.ValueOutsideSection,

            // Unknown sections are skipped until the next blank line/header.
            .ignore => {},

            .name => try setDescValue(&result.name, line),
            .version => try setDescValue(&result.version, line),
            .base => try setDescValue(&result.base, line),
            .description => try setDescValue(&result.description, line),
            .url => try setDescValue(&result.url, line),
            .architecture => try setDescValue(&result.architecture, line),
            .packager => try setDescValue(&result.packager, line),
            .installed_database => try setDescValue(&result.installed_database, line),

            .repository_filename => try setDescValue(&result.repository_filename, line),
            .md5_sum => try setDescValue(&result.md5_sum, line),
            .sha256_sum => try setDescValue(&result.sha256_sum, line),
            .base64_signature => try setDescValue(&result.base64_signature, line),
            .compressed_size => {
                if (result.compressed_size != null) return error.DuplicateValue;
                result.compressed_size = try std.fmt.parseInt(u64, line, 10);
            },
            .files => try result.files.append(
                allocator,
                .{
                    .name = line,
                    .kind = if (std.mem.endsWith(u8, line, "/"))
                        .directory
                    else
                        .unknown,
                },
            ),
            .backups => try result.backups.append(allocator, try BackupFile.parseLocal(line)),
            .groups => try result.groups.append(allocator, line),
            .licenses => try result.licenses.append(allocator, line),

            .build_date => {
                if (result.build_date != null)
                    return error.DuplicateValue;

                result.build_date = try std.fmt.parseInt(
                    i64,
                    line,
                    10,
                );
            },

            .install_date => {
                if (result.install_date != null)
                    return error.DuplicateValue;

                result.install_date = try std.fmt.parseInt(
                    i64,
                    line,
                    10,
                );
            },

            .installed_size => {
                if (result.installed_size != null)
                    return error.DuplicateValue;

                result.installed_size = try std.fmt.parseInt(
                    u64,
                    line,
                    10,
                );
            },

            .reason => {
                if (result.reason != null)
                    return error.DuplicateValue;

                result.reason = if (std.mem.eql(u8, line, "0"))
                    .explicit
                else if (std.mem.eql(u8, line, "1"))
                    .dependency
                else
                    .unknown;
            },

            .validation => {
                if (std.mem.eql(u8, line, "none")) {
                    result.validation.none = true;
                } else if (std.mem.eql(u8, line, "md5")) {
                    result.validation.md5 = true;
                } else if (std.mem.eql(u8, line, "sha256")) {
                    result.validation.sha256 = true;
                } else if (std.mem.eql(u8, line, "pgp")) {
                    result.validation.pgp = true;
                }

                // Unknown values are ignored, matching libalpm's
                // forward-compatible behavior.
            },

            .depends => {
                try result.depends.append(allocator, line);
            },

            .optional_depends => {
                try result.optional_depends.append(allocator, line);
            },

            .make_depends => {
                try result.make_depends.append(allocator, line);
            },

            .check_depends => {
                try result.check_depends.append(allocator, line);
            },

            .conflicts => {
                try result.conflicts.append(allocator, line);
            },

            .provides => {
                try result.provides.append(allocator, line);
            },

            .replaces => {
                try result.replaces.append(allocator, line);
            },

            .xdata => {
                const equals_index =
                    std.mem.indexOfScalar(u8, line, '=') orelse
                    return error.InvalidXData;

                if (equals_index == 0)
                    return error.InvalidXData;

                try result.xdata.append(allocator, .{
                    .name = line[0..equals_index],
                    .value = line[equals_index + 1 ..],
                });
            },
        }
    }

    return result;
}

pub fn descSectionFromHeader(header: []const u8) DescSection {
    if (std.mem.eql(u8, header, "%NAME%"))
        return .name;

    if (std.mem.eql(u8, header, "%VERSION%"))
        return .version;

    if (std.mem.eql(u8, header, "%BASE%"))
        return .base;

    if (std.mem.eql(u8, header, "%DESC%"))
        return .description;

    if (std.mem.eql(u8, header, "%GROUPS%"))
        return .groups;

    if (std.mem.eql(u8, header, "%URL%"))
        return .url;

    if (std.mem.eql(u8, header, "%LICENSE%"))
        return .licenses;

    if (std.mem.eql(u8, header, "%ARCH%"))
        return .architecture;

    if (std.mem.eql(u8, header, "%BUILDDATE%"))
        return .build_date;

    if (std.mem.eql(u8, header, "%INSTALLDATE%"))
        return .install_date;

    if (std.mem.eql(u8, header, "%PACKAGER%"))
        return .packager;

    if (std.mem.eql(u8, header, "%INSTALLED_DB%"))
        return .installed_database;

    if (std.mem.eql(u8, header, "%SIZE%"))
        return .installed_size;

    // Synchronized repository databases use ISIZE for installed size.
    if (std.mem.eql(u8, header, "%ISIZE%"))
        return .installed_size;

    if (std.mem.eql(u8, header, "%REASON%"))
        return .reason;

    if (std.mem.eql(u8, header, "%VALIDATION%"))
        return .validation;

    if (std.mem.eql(u8, header, "%DEPENDS%"))
        return .depends;

    if (std.mem.eql(u8, header, "%OPTDEPENDS%"))
        return .optional_depends;

    if (std.mem.eql(u8, header, "%MAKEDEPENDS%"))
        return .make_depends;

    if (std.mem.eql(u8, header, "%CHECKDEPENDS%"))
        return .check_depends;

    if (std.mem.eql(u8, header, "%CONFLICTS%"))
        return .conflicts;

    if (std.mem.eql(u8, header, "%PROVIDES%"))
        return .provides;

    if (std.mem.eql(u8, header, "%REPLACES%"))
        return .replaces;

    if (std.mem.eql(u8, header, "%XDATA%") or std.mem.eql(u8, header, "%DATA%"))
        return .xdata;

    if (std.mem.eql(u8, header, "%FILENAME%")) return .repository_filename;
    if (std.mem.eql(u8, header, "%MD5SUM%")) return .md5_sum;
    if (std.mem.eql(u8, header, "%SHA256SUM%")) return .sha256_sum;
    if (std.mem.eql(u8, header, "%PGPSIG%")) return .base64_signature;
    if (std.mem.eql(u8, header, "%CSIZE%")) return .compressed_size;
    if (std.mem.eql(u8, header, "%FILES%")) return .files;
    if (std.mem.eql(u8, header, "%BACKUP%")) return .backups;

    return .ignore;
}

fn setDescValue(
    destination: *?[]const u8,
    value: []const u8,
) !void {
    if (destination.* != null)
        return error.DuplicateValue;

    destination.* = value;
}

pub const DescSection = enum {
    none,
    ignore,
    name,
    version,
    base,
    description,
    groups,
    url,
    licenses,
    architecture,
    build_date,
    install_date,
    packager,
    installed_database,
    installed_size,
    reason,
    validation,
    depends,
    optional_depends,
    make_depends,
    check_depends,
    conflicts,
    provides,
    replaces,
    xdata,
    repository_filename,
    md5_sum,
    sha256_sum,
    base64_signature,
    compressed_size,
    files,
    backups,
};

test "ParsedDescription defaults to empty and releases list storage" {
    const allocator = std.testing.allocator;
    var parsed: ParsedDescription = .{};
    defer parsed.deinit(allocator);

    try parsed.groups.append(allocator, "base");
    try parsed.depends.append(allocator, "glibc>=2.39");
    try parsed.xdata.append(allocator, .{
        .name = "pkgtype",
        .value = "pkg",
    });

    try std.testing.expect(parsed.name == null);
    try std.testing.expectEqualStrings("base", parsed.groups.items[0]);
    try std.testing.expectEqualStrings("glibc>=2.39", parsed.depends.items[0]);
    try std.testing.expectEqualStrings("pkgtype", parsed.xdata.items[0].name);
}

test "ParsedDescription converts local metadata into an arena-owned package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed: ParsedDescription = .{
        .name = "demo",
        .version = "1.2.3-4",
        .description = "Demo package",
        .installed_size = 4096,
        .reason = .dependency,
        .validation = .{ .sha256 = true, .pgp = true },
    };
    defer parsed.deinit(allocator);

    try parsed.depends.append(allocator, "glibc>=2.39");
    try parsed.optional_depends.append(allocator, "docs: documentation support");
    try parsed.groups.append(allocator, "base");

    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });

    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("0", package.version.epoch);
    try std.testing.expectEqualStrings("1.2.3", package.version.pkgver);
    try std.testing.expectEqualStrings("4", package.version.pkgrel.?);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    switch (package.depends[0].constraint) {
        .greater_equal => |version| try std.testing.expectEqualStrings("2.39", version),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("docs", package.optional_depends[0].name);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
    try std.testing.expectEqualStrings("base", package.groups[0]);
    try std.testing.expectEqual(@as(u64, 4096), package.installed_size.?);
    try std.testing.expect(package.validation.sha256);
    try std.testing.expect(package.validation.pgp);
}

test "ParsedDescription retains large package and provision epochs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed: ParsedDescription = .{
        .name = "demo",
        .version = "18446744073709551616:1.0-1",
    };
    defer parsed.deinit(allocator);
    try parsed.provides.append(allocator, "virtual=00018446744073709551617:2.0");
    try parsed.depends.append(allocator, "runtime>=18446744073709551616:1.0");
    const package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try std.testing.expectEqualStrings("18446744073709551616", package.version.epoch);
    try std.testing.expectEqualStrings("00018446744073709551617:2.0", package.provides[0].constraint.equal);
    try std.testing.expectEqual(
        .greaterThan,
        Version.compareStrings(
            package.provides[0].constraint.equal,
            package.version.raw,
        ),
    );
    try std.testing.expectEqual(
        .equal,
        Version.compareStrings(
            package.depends[0].constraint.greater_equal,
            package.version.raw,
        ),
    );
}

test "ParsedDescription preserves permissive package and relation versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "+1:1.0", "1_0:1.0" }) |invalid| {
        var parsed: ParsedDescription = .{ .name = "demo", .version = invalid };
        defer parsed.deinit(allocator);
        _ = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
        parsed.version = "1.0";
        try parsed.provides.append(allocator, try std.fmt.allocPrint(allocator, "virtual={s}", .{invalid}));
        _ = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    }
}
