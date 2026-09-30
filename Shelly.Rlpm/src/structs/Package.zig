const std = @import("std");
const Version = @import("Version.zig");
const PackageRelation = @import("PackageRelation.zig");
const ParsedDescription = @import("ParsedDescription.zig");
const ArchiveReader = @import("ArchiveReader.zig");
const MtreeIterator = @import("MtreeIterator.zig");
const PackageFile = @import("PackageFile.zig");
const BackupFile = @import("BackupFile.zig");
const DatabaseRecord = @import("DatabaseRecord.zig");
const ImmutableFile = @import("ImmutableFile.zig");
const SignaturePolicy = @import("SignaturePolicy.zig");
const DatabaseRef = @import("DatabaseRef.zig");
const OpenPgp = @import("OpenPgp.zig");
const Checksum = @import("Checksum.zig");
const MemberReader = @import("MemberReader.zig");

const Package = @This();

const c = ArchiveReader.c;

pub const Origin = enum { local, sync, archive };

pub const Source = struct {
    origin: Origin,
    database_name: []const u8 = "",
    archive_path: ?[]const u8 = null,
    metadata_directory: ?[]const u8 = null,
};

pub const Availability = enum { unknown, absent, present };

pub const Member = enum { install, changelog, mtree };

pub const LoadOptions = struct {
    mode: enum { metadata, full } = .metadata,
};

pub const Members = struct {
    install: Availability = .unknown,
    changelog: Availability = .unknown,
    mtree: Availability = .unknown,
};

pub const InstallReason = enum {
    explicit,
    dependency,
    unknown,
};

pub const Validation = struct {
    none: bool = false,
    md5: bool = false,
    sha256: bool = false,
    pgp: bool = false,
};

pub const XData = struct {
    name: []const u8,
    value: []const u8,
};

name: []const u8,
version: Version,
database_name: []const u8,
origin: Origin = .local,
archive_path: ?[]const u8 = null,
metadata_directory: ?[]const u8 = null,
description_loaded: bool = true,
metadata_error: ?anyerror = null,
metadata_issues: DatabaseRecord.Issues = .{},
repository_filename: ?[]const u8 = null,
compressed_size: ?u64 = null,
/// Remaining transfer after cache planning; null means not planned yet.
download_size: ?u64 = null,
md5_sum: ?[]const u8 = null,
sha256_sum: ?[]const u8 = null,
base64_signature: ?[]const u8 = null,
files: []const PackageFile = &.{},
backups: []const BackupFile = &.{},
files_loaded: bool = false,
files_source: enum { none, database, archive, mtree } = .none,
members: Members = .{},
has_scriptlet: bool = false,
installed_database: ?[]const u8 = null,
base: ?[]const u8 = null,
description: ?[]const u8 = null,
provides: []const PackageRelation = &.{},
depends: []const PackageRelation = &.{},
optional_depends: []const PackageRelation = &.{},
make_depends: []const PackageRelation = &.{},
check_depends: []const PackageRelation = &.{},
conflicts: []const PackageRelation = &.{},
replaces: []const PackageRelation = &.{},
install_reason: ?InstallReason = null,
validation: Validation = .{},
url: ?[]const u8 = null,
architecture: ?[]const u8 = null,
build_date: ?i64 = null,
install_date: ?i64 = null,
installed_size: ?u64 = null,
packager: ?[]const u8 = null,
groups: []const []const u8 = &.{},
licenses: []const []const u8 = &.{},
xdata: []const XData = &.{},
archive_arena: ?std.heap.ArenaAllocator = null,
/// Owned only by verified archive packages. Member/payload readers reopen this
/// sealed file, while archive_path retains the caller's original pathname.
verified_archive: ?ImmutableFile = null,
/// Preserve the source's effective policy for transaction preflight rechecks.
archive_signature_policy: ?SignaturePolicy = null,
archive_source: enum { local_file, remote_file, repository } = .local_file,
archive_repository: ?DatabaseRef = null,

/// Compatibility entry point for metadata loading. This does not verify payloads
/// or signatures. The owned result must be released exactly once with deinit.
pub fn initializePackageFromArchive(allocator: std.mem.Allocator, path: []const u8) !Package {
    return loadArchive(allocator, path, .{});
}

/// Full mode uses .MTREE inventory when present, as libalpm does. It may therefore
/// stop before the payload ends; full inventory is not a payload-integrity proof.
pub fn loadArchive(allocator: std.mem.Allocator, path: []const u8, options: LoadOptions) !Package {
    var reader = try ArchiveReader.openFile(allocator, path);
    defer reader.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var parsed: ParsedDescription = .{};
    defer parsed.deinit(owned);
    var config = false;
    var hit_mtree = false;
    var members: Members = .{};
    var scriptlet = false;
    while (true) {
        const entry = (try reader.next()) orelse {
            inline for (std.meta.fields(Members)) |field|
                if (@field(members, field.name) == .unknown) {
                    @field(members, field.name) = .absent;
                };
            break;
        };
        const name = ArchiveReader.normalizedName(entry.name);
        if (std.mem.eql(u8, name, ".PKGINFO")) {
            if (entry.kind != .regular) return error.InvalidPkginfo;
            if (entry.size.? > max_pkginfo_size) return error.PkginfoTooLarge;
            const contents = reader.readAll(owned, max_pkginfo_size) catch |err|
                return if (err == error.MetadataTooLarge)
                    error.PkginfoTooLarge
                else
                    err;
            try parsePkginfo(&parsed, owned, contents);
            try checkArchiveIdentity(&parsed);
            config = true;
            continue;
        }
        if (std.mem.eql(u8, name, ".INSTALL")) {
            members.install = .present;
            scriptlet = true;
            continue;
        }
        if (std.mem.eql(u8, name, ".CHANGELOG")) members.changelog = .present;
        if (std.mem.eql(u8, name, ".MTREE")) {
            members.mtree = .present;
            if (options.mode == .full) {
                const bytes = try reader.readAll(owned, max_mtree_size);
                // Invalid mtree falls back to the archive inventory, like libalpm.
                if (readMtreeFiles(owned, bytes)) |inventory| {
                    parsed.files = inventory.files;
                    scriptlet = scriptlet or inventory.scriptlet;
                    if (inventory.scriptlet) members.install = .present;
                    hit_mtree = true;
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    // The pinned library crashes for a valid mtree followed by
                    // an invalid duplicate. Report the malformed input safely.
                    else => if (hit_mtree) return error.InvalidMtree,
                }
                continue;
            }
        }
        if (std.mem.startsWith(u8, name, ".")) continue;
        if (options.mode == .full and !hit_mtree) try appendFile(owned, &parsed.files, entry);
        try reader.skip();
        if (config and (options.mode == .metadata or hit_mtree)) break;
    }
    if (!config) return error.MissingPkginfo;
    try checkPackageMetadata(&parsed);
    parsed.files_loaded = options.mode == .full;
    parsed.compressed_size = reader.file_size;
    parsed.validation.none = true;
    var package = try parsed.intoPackage(&arena, .{ .origin = .archive, .archive_path = path });
    try reader.finish();
    package.archive_arena = arena;
    package.members = members;
    package.has_scriptlet = scriptlet;
    package.files_source = if (options.mode == .metadata) .none else if (hit_mtree) .mtree else .archive;
    return package;
}

fn checkArchiveIdentity(parsed: *const ParsedDescription) !void {
    const name = parsed.name orelse return error.MissingPackageName;
    if (name.len == 0) return error.MissingPackageName;
    const version = parsed.version orelse return error.MissingPackageVersion;
    if (version.len == 0 or std.mem.indexOfScalar(u8, version, '-') == null) return error.InvalidVersion;
}

fn checkPackageMetadata(parsed: *const ParsedDescription) !void {
    const name = parsed.name.?;
    const version = parsed.version.?;
    if (name[0] == '.' or name[0] == '-') return error.InvalidPackageName;
    for (name) |byte|
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "+_.@-", byte) == null)
            return error.InvalidPackageName;
    if (std.mem.count(u8, version, "-") > 1 or std.mem.indexOfScalar(u8, version, '/') != null)
        return error.InvalidVersion;
    if (name.len + version.len + 1 > 255) return error.InvalidPackageName;
}

fn appendFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayList(PackageFile),
    entry: PackageFile,
) !void {
    var file = entry;
    const name = ArchiveReader.normalizedName(entry.name);
    file.name = if (file.kind == .directory and !std.mem.endsWith(u8, name, "/"))
        try std.fmt.allocPrint(
            allocator,
            "{s}/",
            .{name},
        )
    else
        try allocator.dupe(u8, name);
    file.link_target = if (entry.link_target) |link| try allocator.dupe(u8, link) else null;
    try files.append(allocator, file);
}

const MtreeInventory = struct {
    files: std.ArrayList(PackageFile) = .empty,
    scriptlet: bool = false,
};

fn readMtreeFiles(allocator: std.mem.Allocator, bytes: []const u8) !MtreeInventory {
    var reader = try ArchiveReader.openMemory(bytes, .mtree);
    defer reader.deinit();
    var result: MtreeInventory = .{};
    while (try reader.next()) |entry| {
        const name = ArchiveReader.normalizedName(entry.name);
        if (std.mem.eql(u8, name, ".INSTALL")) result.scriptlet = true;
        if (std.mem.startsWith(u8, name, ".")) continue;
        try appendFile(allocator, &result.files, entry);
    }
    return result;
}

pub fn satisfies(self: *const Package, requirement: PackageRelation) bool {
    return requirement.satisfiedBy(self.name, self.version.raw, self.provides);
}

pub fn findFile(self: *const Package, path: []const u8) ?*const PackageFile {
    var lo: usize = 0;
    var hi = self.files.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, self.files[mid].name, path)) {
            .eq => return &self.files[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// The caller owns the decoded bytes. Decoding is not signature verification.
pub fn decodeSignature(self: *const Package, allocator: std.mem.Allocator) !?[]u8 {
    const encoded = self.base64_signature orelse return null;
    return try OpenPgp.decode(allocator, encoded);
}

/// Available metadata, not evidence that the corresponding checks have run.
pub fn availableValidation(self: *const Package) Validation {
    return .{
        .none = self.md5_sum == null and self.sha256_sum == null and self.base64_signature == null,
        .md5 = self.md5_sum != null,
        .sha256 = self.sha256_sum != null,
        .pgp = self.base64_signature != null,
    };
}

/// Embedded signature first, otherwise a sidecar beside the supplied cache file
/// (or this archive). A cache path is required for a repository-only package.
pub fn getSignature(
    self: *const Package,
    allocator: std.mem.Allocator,
    io: std.Io,
    cached_path: ?[]const u8,
) !?[]u8 {
    if (self.base64_signature != null) return self.decodeSignature(allocator);
    const path = cached_path orelse self.archive_path orelse return error.PackageArchiveRequired;
    return OpenPgp.readDetached(allocator, io, path);
}

pub fn checkMd5sum(self: *const Package, io: std.Io, cached_path: []const u8) !void {
    if (self.origin != .sync) return error.UnsupportedPackageOrigin;
    try Checksum.check(
        .md5,
        io,
        cached_path,
        self.md5_sum orelse return error.ChecksumMissing,
    );
}

/// Readers opened here remain valid after package release. Verified packages
/// always use the same bytes checked by Owner.loadPackage.
pub fn openArchive(self: *const Package, allocator: std.mem.Allocator) !ArchiveReader {
    if (self.origin != .archive) return error.UnsupportedPackageOrigin;
    const path = if (self.verified_archive) |*snapshot|
        snapshot.path()
    else
        self.archive_path orelse
            return error.InvalidPath;
    return ArchiveReader.openFile(allocator, path);
}

/// Reopens the archive independently. The returned reader remains valid after
/// package release, and must be deinitialized even after read errors.
pub fn openMember(self: *const Package, allocator: std.mem.Allocator, member: Member) !?MemberReader {
    if (self.origin == .local and self.metadata_directory != null) {
        const path = try std.fs.path.join(allocator, &.{ self.metadata_directory.?, @tagName(member) });
        defer allocator.free(path);
        return MemberReader.openFile(allocator, path);
    }
    if (self.origin != .archive) return error.UnsupportedPackageOrigin;
    var reader = try self.openArchive(allocator);
    errdefer reader.deinit();
    const wanted = switch (member) {
        .install => ".INSTALL",
        .changelog => ".CHANGELOG",
        .mtree => ".MTREE",
    };
    while (try reader.next()) |entry| {
        if (std.mem.eql(u8, ArchiveReader.normalizedName(entry.name), wanted)) {
            if (entry.kind != .regular) return error.InvalidArchiveEntry;
            return .{ .stream = .{ .archive = reader } };
        }
        try reader.skip();
    }
    reader.deinit();
    return null;
}

pub fn openMtree(self: *const Package, allocator: std.mem.Allocator) !?MtreeIterator {
    var member = (try self.openMember(allocator, .mtree)) orelse return null;
    defer member.deinit();
    const bytes = try member.readAll(allocator, max_mtree_size);
    errdefer allocator.free(bytes);
    return try MtreeIterator.initOwned(allocator, bytes);
}

/// Releases archive-owned storage. Database packages remain owned by their database.
pub fn deinit(self: *Package) void {
    if (self.verified_archive) |*snapshot| snapshot.deinit();
    if (self.archive_arena) |*arena| arena.deinit();
    self.* = undefined;
}

const max_pkginfo_size = 1 << 20;
const max_mtree_size = 32 << 20;

fn parsePkginfo(
    parsed: *ParsedDescription,
    allocator: std.mem.Allocator,
    contents: []const u8,
) !void {
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return error.InvalidPkginfo;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len > 512 * 1024) return error.MetadataLineTooLong;
        // Retain the existing CRLF input convenience; values otherwise keep
        // their exact whitespace, as in the reference's "key = value" parser.
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.startsWith(u8, line[separator..], " = ")) continue;
        const key = line[0..separator];
        const value = line[separator + 3 ..];
        if (key.len == 0) continue;

        const strings = .{
            .{ "pkgname", "name" },      .{ "pkgver", "version" },
            .{ "pkgbase", "base" },      .{ "pkgdesc", "description" },
            .{ "url", "url" },           .{ "arch", "architecture" },
            .{ "packager", "packager" },
        };
        inline for (strings) |field| {
            if (std.mem.eql(u8, key, field[0])) {
                @field(parsed, field[1]) = value;
            }
        }
        const lists = .{
            .{ "group", "groups" },            .{ "license", "licenses" },
            .{ "depend", "depends" },          .{ "optdepend", "optional_depends" },
            .{ "makedepend", "make_depends" }, .{ "checkdepend", "check_depends" },
            .{ "conflict", "conflicts" },      .{ "provides", "provides" },
            .{ "replaces", "replaces" },
        };
        inline for (lists) |field| {
            if (std.mem.eql(u8, key, field[0]))
                try @field(parsed, field[1]).append(allocator, value);
        }
        if (std.mem.eql(u8, key, "builddate")) {
            parsed.build_date = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, key, "size")) {
            parsed.installed_size = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "backup")) {
            try parsed.backups.append(allocator, .{ .name = value });
        } else if (std.mem.eql(u8, key, "xdata")) {
            const equals = std.mem.indexOfScalar(u8, value, '=') orelse
                return error.InvalidXData;
            if (equals == 0) return error.InvalidXData;
            try parsed.xdata.append(allocator, .{
                .name = value[0..equals],
                .value = value[equals + 1 ..],
            });
        }
        // Unknown keys are ignored for compatibility with newer metadata formats.
    }
}

test "Package stores version, database, and package relations" {
    var version = try Version.init("0:1.27.0-2", std.testing.allocator);
    defer version.deinit(std.testing.allocator);

    var provides = [_]PackageRelation{
        .{ .name = "go", .constraint = .any },
    };
    var depends = [_]PackageRelation{
        .{ .name = "glibc", .constraint = .any },
    };
    var no_relations = [_]PackageRelation{};

    const package: Package = .{
        .name = "go",
        .version = version,
        .database_name = "core",
        .provides = provides[0..],
        .depends = depends[0..],
        .make_depends = no_relations[0..],
        .conflicts = no_relations[0..],
        .replaces = no_relations[0..],
    };

    try std.testing.expectEqualStrings("go", package.name);
    try std.testing.expectEqualStrings("0:1.27.0-2", package.version.raw);
    try std.testing.expectEqualStrings("core", package.database_name);
    try std.testing.expectEqualStrings("go", package.provides[0].name);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    try std.testing.expectEqual(@as(usize, 0), package.conflicts.len);
}

const ArchiveFixture = struct {
    temporary: std.testing.TmpDir,
    path: [:0]u8,

    const Entry = struct {
        path: [:0]const u8 = ".PKGINFO",
        contents: []const u8 = "",
        kind: c_uint = 0o100000,
        size: ?usize = null,
    };

    fn init(entries: []const Entry, compressed: bool) !ArchiveFixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const allocator = std.testing.allocator;
        const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(directory);
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/package.tar", .{directory}, 0);
        errdefer allocator.free(path);

        const writer = c.archive_write_new() orelse return error.OutOfMemory;
        defer _ = c.archive_write_free(writer);
        if (compressed) try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_add_filter_zstd(writer));
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_format_pax_restricted(writer));
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_open_filename(writer, path.ptr));
        for (entries) |item| {
            const entry = c.archive_entry_new() orelse return error.OutOfMemory;
            defer c.archive_entry_free(entry);
            c.archive_entry_set_pathname(entry, item.path.ptr);
            c.archive_entry_set_filetype(entry, item.kind);
            c.archive_entry_set_perm(entry, 0o644);
            c.archive_entry_set_size(entry, @intCast(item.size orelse item.contents.len));
            try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_header(writer, entry));
            if (item.contents.len != 0) {
                try std.testing.expectEqual(
                    @as(isize, @intCast(item.contents.len)),
                    c.archive_write_data(writer, item.contents.ptr, item.contents.len),
                );
            }
            try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_finish_entry(writer));
        }
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_close(writer));
        return .{ .temporary = temporary, .path = path };
    }

    fn deinit(self: *ArchiveFixture) void {
        std.testing.allocator.free(self.path);
        self.temporary.cleanup();
    }
};

const archive_pkginfo_fixture =
    "# Generated package metadata\r\n" ++
    "pkgname = demo\r\n" ++
    "pkgver = 2:1.2.3-4\n" ++
    "pkgbase = demo-base\npkgdesc = Demo = package\n" ++
    "url = https://example.invalid/demo\narch = x86_64\n" ++
    "builddate = 1720000000\nsize = 4096\npackager = Example Builder\n" ++
    "group = utilities\ngroup = tools\nlicense = MIT\nlicense = BSD\n" ++
    "depend = glibc>=2.39\ndepend = runtime\n" ++
    "optdepend = docs>=1:2.0: documentation support\n" ++
    "makedepend = compiler\ncheckdepend = tester\n" ++
    "conflict = old-demo<1.0\nprovides = virtual-demo=2:1.2.3\n" ++
    "replaces = old-demo<=0.9\nxdata = pkgtype=pkg\n" ++
    "xdata = custom=a=b\nfuturekey = ignored\n";

test "archive package reads metadata and relations with owned storage" {
    for ([_]bool{ false, true }) |compressed| {
        var fixture = try ArchiveFixture.init(&.{
            .{ .path = "usr/bin/demo", .contents = "payload skipped" },
            .{ .path = "./.PKGINFO", .contents = archive_pkginfo_fixture },
        }, compressed);
        defer fixture.deinit();
        // Pass a non-sentinel-terminated slice; only the requested path is opened.
        const longer_path = try std.fmt.allocPrint(std.testing.allocator, "{s}suffix", .{fixture.path});
        defer std.testing.allocator.free(longer_path);
        var package = try initializePackageFromArchive(
            std.testing.allocator,
            longer_path[0..fixture.path.len],
        );
        defer package.deinit();

        try std.testing.expectEqualStrings("demo", package.name);
        try std.testing.expectEqualStrings("2:1.2.3-4", package.version.raw);
        try std.testing.expectEqualStrings("", package.database_name);
        try std.testing.expectEqualStrings("demo-base", package.base.?);
        try std.testing.expectEqualStrings("Demo = package", package.description.?);
        try std.testing.expectEqualStrings("https://example.invalid/demo", package.url.?);
        try std.testing.expectEqualStrings("x86_64", package.architecture.?);
        try std.testing.expectEqualStrings("Example Builder", package.packager.?);
        try std.testing.expectEqual(@as(i64, 1720000000), package.build_date.?);
        try std.testing.expectEqual(@as(u64, 4096), package.installed_size.?);
        try std.testing.expectEqual(@as(usize, 2), package.groups.len);
        try std.testing.expectEqualStrings("tools", package.groups[1]);
        try std.testing.expectEqualStrings("BSD", package.licenses[1]);
        try std.testing.expectEqual(@as(usize, 2), package.depends.len);
        try std.testing.expectEqualStrings("2.39", package.depends[0].constraint.greater_equal);
        try std.testing.expect(package.depends[1].constraint == .any);
        try std.testing.expectEqualStrings("docs", package.optional_depends[0].name);
        try std.testing.expectEqualStrings("1:2.0", package.optional_depends[0].constraint.greater_equal);
        try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
        try std.testing.expectEqualStrings("compiler", package.make_depends[0].name);
        try std.testing.expectEqualStrings("tester", package.check_depends[0].name);
        try std.testing.expectEqualStrings("1.0", package.conflicts[0].constraint.less);
        try std.testing.expectEqualStrings("2:1.2.3", package.provides[0].constraint.equal);
        try std.testing.expectEqualStrings("0.9", package.replaces[0].constraint.less_equal);
        try std.testing.expectEqualStrings("pkgtype", package.xdata[0].name);
        try std.testing.expectEqualStrings("a=b", package.xdata[1].value);
        try std.testing.expectEqual(.explicit, package.install_reason.?);
        try std.testing.expect(package.installed_database == null);
        try std.testing.expect(package.install_date == null);
        try std.testing.expect(!package.validation.pgp and !package.validation.sha256);
    }
}

test "archive package rejects missing invalid and oversized metadata" {
    const cases = [_]struct {
        entry: ArchiveFixture.Entry,
        expected: anyerror,
    }{
        .{ .entry = .{ .path = "nested/.PKGINFO" }, .expected = error.MissingPkginfo },
        .{ .entry = .{ .kind = 0o040000 }, .expected = error.MissingPkginfo },
        .{ .entry = .{ .size = max_pkginfo_size + 1 }, .expected = error.PkginfoTooLarge },
        .{ .entry = .{ .contents = "pkgver = 1\n" }, .expected = error.MissingPackageName },
        .{ .entry = .{ .contents = "pkgname = demo\n" }, .expected = error.MissingPackageVersion },
        .{ .entry = .{ .contents = "pkgname = demo\npkgver = \n" }, .expected = error.InvalidVersion },
        .{
            .entry = .{ .contents = "pkgname = demo\npkgname = duplicate\n" },
            .expected = error.MissingPackageVersion,
        },
        .{ .entry = .{ .contents = "invalid line\n" }, .expected = error.MissingPackageName },
        .{ .entry = .{ .contents = "pkgname = demo\x00\n" }, .expected = error.InvalidPkginfo },
        .{ .entry = .{ .contents = "size = -1\n" }, .expected = error.Overflow },
        .{ .entry = .{ .contents = "xdata = missing-equals\n" }, .expected = error.InvalidXData },
        .{
            .entry = .{ .contents = archive_pkginfo_fixture ++ "pkgname = .invalid\n" },
            .expected = error.InvalidPackageName,
        },
    };
    for (cases) |case| {
        var fixture = try ArchiveFixture.init(&.{case.entry}, true);
        defer fixture.deinit();
        try std.testing.expectError(
            case.expected,
            initializePackageFromArchive(
                std.testing.allocator,
                fixture.path,
            ),
        );
    }
}

test "archive package rejects invalid paths and unreadable archives" {
    try std.testing.expectError(
        error.InvalidPath,
        initializePackageFromArchive(
            std.testing.allocator,
            "bad\x00path",
        ),
    );
    var fixture = try ArchiveFixture.init(&.{}, false);
    defer fixture.deinit();
    try fixture.temporary.dir.writeFile(
        std.testing.io,
        .{
            .sub_path = "package.tar",
            .data = "not an archive",
        },
    );
    try std.testing.expectError(
        error.ArchiveFailed,
        initializePackageFromArchive(
            std.testing.allocator,
            fixture.path,
        ),
    );
    try fixture.temporary.dir.deleteFile(std.testing.io, "package.tar");
    try std.testing.expectError(
        error.ArchiveFailed,
        initializePackageFromArchive(
            std.testing.allocator,
            fixture.path,
        ),
    );
}

test "archive package rejects truncated metadata" {
    var fixture = try ArchiveFixture.init(&.{.{ .contents = archive_pkginfo_fixture }}, false);
    defer fixture.deinit();
    const contents = try fixture.temporary.dir.readFileAlloc(
        std.testing.io,
        "package.tar",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(contents);
    // Retain the tar header but cut off the metadata body.
    try fixture.temporary.dir.writeFile(
        std.testing.io,
        .{
            .sub_path = "package.tar",
            .data = contents[0..520],
        },
    );
    try std.testing.expectError(
        error.ArchiveFailed,
        initializePackageFromArchive(
            std.testing.allocator,
            fixture.path,
        ),
    );
}

fn checkArchiveAllocationFailures(allocator: std.mem.Allocator, path: []const u8) !void {
    var package = try initializePackageFromArchive(allocator, path);
    defer package.deinit();
}

test "archive package cleans up after allocation failures" {
    var fixture = try ArchiveFixture.init(&.{.{ .contents = archive_pkginfo_fixture }}, true);
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkArchiveAllocationFailures,
        .{fixture.path},
    );
}
