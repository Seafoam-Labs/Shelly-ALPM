//! Reads the `.PKGINFO` control member of an Arch package archive and the
//! member list that a repository `files` database entry is built from.

const std = @import("std");
const archive = @import("archive");

const Allocator = std.mem.Allocator;
const Reader = archive.Reader;

pub const Error = error{
    /// The file is not an archive libarchive recognizes, or holds no `.PKGINFO`.
    NotAPackage,
    /// `.PKGINFO` was read but names no package, so no entry can be derived.
    MissingPkginfo,
};

/// `.PKGINFO` is a control file, so anything larger is either a misreported or
/// a hostile archive entry. Readers bound their copy by this cap instead of
/// trusting the header size.
pub const max_pkginfo_size = 1 << 20;

const pkginfo_path = ".PKGINFO";
const read_chunk_size = 8 * 1024;

/// The values a repository entry is derived from. A zero-length value means
/// the key was absent, which lets writers omit the section entirely.
pub const PkgInfo = struct {
    pkgname: []const u8 = "",
    pkgbase: []const u8 = "",
    pkgver: []const u8 = "",
    pkgdesc: []const u8 = "",
    url: []const u8 = "",
    arch: []const u8 = "",
    builddate: []const u8 = "",
    packager: []const u8 = "",
    size: []const u8 = "",
    groups: []const []const u8 = &.{},
    licenses: []const []const u8 = &.{},
    replaces: []const []const u8 = &.{},
    depends: []const []const u8 = &.{},
    optdepends: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    makedepends: []const []const u8 = &.{},
    checkdepends: []const []const u8 = &.{},

    pub fn deinit(self: *PkgInfo, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(PkgInfo).@"struct".fields) |field| switch (field.type) {
            []const u8 => allocator.free(@field(self, field.name)),
            []const []const u8 => freeValues(allocator, @field(self, field.name)),
            else => @compileError("PkgInfo field is not owned text: " ++ field.name),
        };
        self.* = undefined;
    }

    /// Assigns a singular key. Field names are the `.PKGINFO` keys, so a key
    /// that repeats keeps the last value.
    fn setSingular(
        self: *PkgInfo,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!bool {
        inline for (@typeInfo(PkgInfo).@"struct".fields) |field| {
            if (field.type != []const u8) continue;
            if (std.mem.eql(u8, key, field.name)) {
                const owned = try normalizeValue(allocator, value);
                allocator.free(@field(self, field.name));
                @field(self, field.name) = owned;
                return true;
            }
        }
        return false;
    }
};

/// Ordered values keyed by the singular `.PKGINFO` name that collects them.
const ValueLists = struct {
    groups: std.ArrayList([]const u8) = .empty,
    licenses: std.ArrayList([]const u8) = .empty,
    replaces: std.ArrayList([]const u8) = .empty,
    depends: std.ArrayList([]const u8) = .empty,
    optdepends: std.ArrayList([]const u8) = .empty,
    conflicts: std.ArrayList([]const u8) = .empty,
    provides: std.ArrayList([]const u8) = .empty,
    makedepends: std.ArrayList([]const u8) = .empty,
    checkdepends: std.ArrayList([]const u8) = .empty,

    fn append(
        self: *ValueLists,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!void {
        const list = self.listFor(key) orelse return;
        const owned = try normalizeValue(allocator, value);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }

    /// Resolves the singular `.PKGINFO` key of each ordered list.
    fn listFor(self: *ValueLists, key: []const u8) ?*std.ArrayList([]const u8) {
        inline for (.{
            .{ "group", "groups" },
            .{ "license", "licenses" },
            .{ "replaces", "replaces" },
            .{ "depend", "depends" },
            .{ "conflict", "conflicts" },
            .{ "provides", "provides" },
            .{ "optdepend", "optdepends" },
            .{ "makedepend", "makedepends" },
            .{ "checkdepend", "checkdepends" },
        }) |pair| {
            if (std.mem.eql(u8, key, pair[0])) return &@field(self, pair[1]);
        }
        return null;
    }

    fn deinit(self: *ValueLists, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(ValueLists).@"struct".fields) |field| {
            const list = &@field(self, field.name);
            freeList(allocator, list);
        }
    }

    /// Moves every list into `info`, whose field names match. A list that was
    /// already moved is empty, so `deinit` stays safe to call afterwards.
    fn moveAll(self: *ValueLists, allocator: std.mem.Allocator, info: *PkgInfo) Allocator.Error!void {
        inline for (@typeInfo(ValueLists).@"struct".fields) |field| {
            var list = &@field(self, field.name);
            @field(info, field.name) = try list.toOwnedSlice(allocator);
        }
    }
};

/// Parses `.PKGINFO` contents. Nothing in a control file is rejected: unknown
/// keys are ignored and a key that is not assigned leaves an empty value.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8) Allocator.Error!PkgInfo {
    var info: PkgInfo = .{};
    errdefer info.deinit(allocator);
    var lists: ValueLists = .{};
    errdefer lists.deinit(allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0 or raw_line[0] == '#') continue;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], &std.ascii.whitespace);
        if (key.len == 0) continue;
        const value = line[separator + 1 ..];
        if (try info.setSingular(allocator, key, value)) continue;
        try lists.append(allocator, key, value);
    }

    try lists.moveAll(allocator, &info);
    return info;
}

/// Reads `.PKGINFO` out of a package archive.
pub fn readFromPackage(
    allocator: std.mem.Allocator,
    package_path: []const u8,
) (Allocator.Error || archive.Error || Error)!PkgInfo {
    var reader = try openPackage(allocator, package_path);
    defer reader.deinit();

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    var buffer: [read_chunk_size]u8 = undefined;

    var found = false;
    while (try reader.next()) |entry| {
        if (entry.kind != .regular_file or !std.mem.eql(u8, entry.path, pkginfo_path)) continue;
        found = true;
        while (true) {
            const amount = try reader.read(&buffer);
            if (amount == 0) break;
            if (contents.items.len + amount > max_pkginfo_size) return error.EntryTooLarge;
            try contents.appendSlice(allocator, buffer[0..amount]);
        }
        break;
    }
    if (!found) return error.NotAPackage;

    var info = try parse(allocator, contents.items);
    errdefer info.deinit(allocator);
    if (info.pkgname.len == 0 or info.pkgver.len == 0) return error.MissingPkginfo;
    return info;
}

/// Lists the archive members that belong to the package, in byte order and
/// with directories marked by a trailing `/`.
pub fn listFilePaths(
    allocator: std.mem.Allocator,
    package_path: []const u8,
) (Allocator.Error || archive.Error || Error)![]const []const u8 {
    var reader = try openPackage(allocator, package_path);
    defer reader.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer freeList(allocator, &paths);

    while (try reader.next()) |entry| {
        // Only archive-root dotfiles carry control data; nested ones such as
        // `usr/.hidden` are ordinary package content.
        if (entry.path.len == 0 or entry.path[0] == '.') continue;
        const path = try ownedEntryPath(allocator, entry);
        try appendPath(allocator, &paths, path);
    }

    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var unique: usize = 0;
    for (paths.items) |path| {
        if (unique != 0 and std.mem.eql(u8, path, paths.items[unique - 1])) {
            allocator.free(path);
            continue;
        }
        paths.items[unique] = path;
        unique += 1;
    }
    paths.shrinkRetainingCapacity(unique);
    return paths.toOwnedSlice(allocator);
}

fn freeValues(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

fn appendPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    path: []const u8,
) Allocator.Error!void {
    paths.append(allocator, path) catch |err| {
        allocator.free(path);
        return err;
    };
}

fn openPackage(
    allocator: std.mem.Allocator,
    package_path: []const u8,
) (Allocator.Error || archive.Error || Error)!Reader {
    return Reader.initAll(allocator, package_path) catch |err| switch (err) {
        error.ArchiveOpenFailed => error.NotAPackage,
        else => err,
    };
}

fn ownedEntryPath(allocator: std.mem.Allocator, entry: archive.Entry) Allocator.Error![]const u8 {
    if (entry.kind != .directory or std.mem.endsWith(u8, entry.path, "/")) {
        return allocator.dupe(u8, entry.path);
    }
    return std.fmt.allocPrint(allocator, "{s}/", .{entry.path});
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Trims the outer whitespace of a value and folds each inner run into one
/// space, so a byte-for-byte comparison of a written entry stays meaningful.
fn normalizeValue(allocator: std.mem.Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);
    var pending_space = false;
    for (std.mem.trim(u8, raw, &std.ascii.whitespace)) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = value.items.len != 0;
            continue;
        }
        if (pending_space) try value.append(allocator, ' ');
        pending_space = false;
        try value.append(allocator, byte);
    }
    return value.toOwnedSlice(allocator);
}

const testing = std.testing;

const pkginfo_fixture =
    \\pkgbase = demo
    \\pkgname = demo
    \\pkgver = 1.0-1
    \\pkgdesc = Demo package
    \\packager = Jane Doe <jane@example.com>
    \\builddate = 1700000000
    \\size = 4096
    \\arch = x86_64
    \\group = tools
    \\group = extra
    \\license = MIT
    \\depend = glibc
;

fn fixturePath(sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

fn expectValues(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "pkginfo parses keys and repeated values" {
    var info = try parse(testing.allocator,
        \\# a comment
        \\pkgname = demo
        \\pkgbase = demo-base
        \\pkgver = 2:1.0-1
        \\pkgdesc = A = B
        \\url=http://example.com/a==b
        \\arch = x86_64
        \\builddate = 1700000000
        \\packager =  Two   Spaces <packager@example.com>
        \\size = 4096
        \\group = tools
        \\group = extras
        \\license = MIT
        \\license = Apache-2.0
        \\replaces = legacy-demo
        \\depend = glibc
        \\depend = sh>=1.0
        \\optdepend = python: for scripting
        \\conflict = other-demo
        \\provides = demo-provider=1.0
        \\makedepend = cmake
        \\checkdepend = bats
        \\checkdepend = diffutils
        \\unknown = ignored
        \\no-separator
        \\
        \\pkgname = demo-renamed
    );
    defer info.deinit(testing.allocator);

    try testing.expectEqualStrings("demo-renamed", info.pkgname);
    try testing.expectEqualStrings("demo-base", info.pkgbase);
    try testing.expectEqualStrings("2:1.0-1", info.pkgver);
    try testing.expectEqualStrings("A = B", info.pkgdesc);
    try testing.expectEqualStrings("http://example.com/a==b", info.url);
    try testing.expectEqualStrings("x86_64", info.arch);
    try testing.expectEqualStrings("1700000000", info.builddate);
    try testing.expectEqualStrings("Two Spaces <packager@example.com>", info.packager);
    try testing.expectEqualStrings("4096", info.size);
    try expectValues(&.{ "tools", "extras" }, info.groups);
    try expectValues(&.{ "MIT", "Apache-2.0" }, info.licenses);
    try expectValues(&.{"legacy-demo"}, info.replaces);
    try expectValues(&.{ "glibc", "sh>=1.0" }, info.depends);
    try expectValues(&.{"python: for scripting"}, info.optdepends);
    try expectValues(&.{"other-demo"}, info.conflicts);
    try expectValues(&.{"demo-provider=1.0"}, info.provides);
    try expectValues(&.{"cmake"}, info.makedepends);
    try expectValues(&.{ "bats", "diffutils" }, info.checkdepends);

    var padded = try parse(testing.allocator, "pkgname =  a  \npkgver = 1\t\npackager =  X  Y  \r\n");
    defer padded.deinit(testing.allocator);
    try testing.expectEqualStrings("a", padded.pkgname);
    try testing.expectEqualStrings("X Y", padded.packager);

    var minimal = try parse(testing.allocator, "pkgname = demo\npkgver = 1-1\n");
    defer minimal.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), minimal.pkgdesc.len);
    try testing.expectEqual(@as(usize, 0), minimal.groups.len);
}

test "pkginfo reads the PKGINFO entry from a package archive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_path = try fixturePath(&tmp.sub_path, "demo-1.0-1-x86_64.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try archive.writeFixture(testing.allocator, package_path, .zstd, &.{
        .{ .path = "usr/bin/tool", .contents = "payload" },
        .{ .path = ".PKGINFO", .contents = pkginfo_fixture },
        .{ .path = ".MTREE", .contents = "# generated by makepkg\n" },
        .{ .path = "usr/", .kind = .directory },
    });

    var info = try readFromPackage(testing.allocator, package_path);
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("demo", info.pkgname);
    try testing.expectEqualStrings("1.0-1", info.pkgver);
    try testing.expectEqualStrings("Demo package", info.pkgdesc);
    try testing.expectEqualStrings("Jane Doe <jane@example.com>", info.packager);
    try expectValues(&.{ "tools", "extra" }, info.groups);

    const duplicate_path = try fixturePath(&tmp.sub_path, "duplicate.pkg.tar.zst");
    defer testing.allocator.free(duplicate_path);
    try archive.writeFixture(testing.allocator, duplicate_path, .zstd, &.{
        .{ .path = ".PKGINFO", .contents = "pkgname = first\npkgver = 1\n" },
        .{ .path = ".PKGINFO", .contents = "pkgname = second\npkgver = 2\n" },
    });
    var duplicate = try readFromPackage(testing.allocator, duplicate_path);
    defer duplicate.deinit(testing.allocator);
    try testing.expectEqualStrings("first", duplicate.pkgname);

    const text_path = try fixturePath(&tmp.sub_path, "notes.txt");
    defer testing.allocator.free(text_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "not an archive\n" });
    try testing.expectError(error.NotAPackage, readFromPackage(testing.allocator, text_path));
}

test "pkginfo rejects archives without PKGINFO" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload_path = try fixturePath(&tmp.sub_path, "payload-only.pkg.tar.zst");
    defer testing.allocator.free(payload_path);
    try archive.writeFixture(testing.allocator, payload_path, .zstd, &.{
        .{ .path = "usr/bin/tool", .contents = "payload" },
    });
    try testing.expectError(error.NotAPackage, readFromPackage(testing.allocator, payload_path));

    const directory_path = try fixturePath(&tmp.sub_path, "directory-pkginfo.pkg.tar.zst");
    defer testing.allocator.free(directory_path);
    try archive.writeFixture(testing.allocator, directory_path, .zstd, &.{
        .{ .path = ".PKGINFO", .kind = .directory },
    });
    try testing.expectError(error.NotAPackage, readFromPackage(testing.allocator, directory_path));

    const incomplete_path = try fixturePath(&tmp.sub_path, "incomplete.pkg.tar.zst");
    defer testing.allocator.free(incomplete_path);
    try archive.writeFixture(testing.allocator, incomplete_path, .zstd, &.{
        .{ .path = ".PKGINFO", .contents = "pkgname = demo\npkgver =\narch = x86_64\n" },
    });
    try testing.expectError(error.MissingPkginfo, readFromPackage(testing.allocator, incomplete_path));
}

test "package file list excludes archive root dotfiles and keeps nested dotfiles" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_path = try fixturePath(&tmp.sub_path, "dotfiles.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try archive.writeFixture(testing.allocator, package_path, .zstd, &.{
        .{ .path = ".PKGINFO", .contents = pkginfo_fixture },
        .{ .path = ".MTREE", .contents = "# generated by makepkg\n" },
        .{ .path = ".BUILDINFO", .contents = "format = 2\n" },
        .{ .path = "usr/", .kind = .directory },
        .{ .path = "usr/.hidden", .contents = "kept" },
        .{ .path = "usr/bin", .kind = .directory },
        .{ .path = "usr/bin/tool", .contents = "payload", .permissions = 0o755 },
        .{ .path = "usr/bin/tool-link", .link_target = "tool" },
    });

    const paths = try listFilePaths(testing.allocator, package_path);
    defer freeValues(testing.allocator, paths);
    try expectValues(&.{
        "usr/",
        "usr/.hidden",
        "usr/bin/",
        "usr/bin/tool",
        "usr/bin/tool-link",
    }, paths);
}

test "package file list is byte-sorted and deduplicated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_path = try fixturePath(&tmp.sub_path, "sorted.pkg.tar.zst");
    defer testing.allocator.free(package_path);
    try archive.writeFixture(testing.allocator, package_path, .zstd, &.{
        .{ .path = ".PKGINFO", .contents = pkginfo_fixture },
        .{ .path = "usr/bin/tool", .contents = "second" },
        .{ .path = "usr/", .kind = .directory },
        .{ .path = "bin", .contents = "first" },
        .{ .path = "usr/bin/tool", .contents = "duplicate" },
        .{ .path = "usr/bin/", .kind = .directory },
        .{ .path = "usr/.hidden", .contents = "hidden" },
    });

    const paths = try listFilePaths(testing.allocator, package_path);
    defer freeValues(testing.allocator, paths);
    try expectValues(&.{ "bin", "usr/", "usr/.hidden", "usr/bin/", "usr/bin/tool" }, paths);
}
