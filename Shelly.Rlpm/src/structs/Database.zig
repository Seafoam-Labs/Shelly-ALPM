const Database = @This();

const std = @import("std");
const Package = @import("Package.zig");
const Group = @import("Group.zig");
const DatabaseStatus = @import("DatabaseStatus.zig");
const SignaturePolicy = @import("SignaturePolicy.zig");
const DatabaseUsage = @import("DatabaseUsage.zig");
const ParsedDescription = @import("ParsedDescription.zig");

pub const PackageId = enum(u32) {
    _,
};

pub const GroupId = enum(u32) {
    _,
};

pub const GroupIndex = struct {
    groups: std.ArrayList(Group) = .empty,
    by_name: std.StringHashMapUnmanaged(GroupId) = .empty,
    ordered: std.ArrayList(GroupId) = .empty,
};

pub const PackageIndex = struct {
    packages: std.ArrayList(Package) = .empty,
    by_name: std.StringHashMapUnmanaged(PackageId) = .empty,
    ordered: std.ArrayList(PackageId) = .empty,
};

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

name: []u8,
path: ?[]u8 = null,

packages: PackageIndex = .{},
groups: GroupIndex = .{},

cache_servers: std.ArrayList([]u8) = .empty,
servers: std.ArrayList([]u8) = .empty,

status: DatabaseStatus = .{},
signature_policy: SignaturePolicy = .{},
usage: DatabaseUsage = .{},

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: ?[]const u8,
) !Database {
    var result: Database = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .name = undefined,
    };
    errdefer result.arena.deinit();

    const database_allocator = result.arena.allocator();
    result.name = try database_allocator.dupe(u8, name);
    if (path) |database_path| {
        result.path = try database_allocator.dupe(u8, database_path);
    }

    return result;
}

pub fn deinit(self: *Database) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn loadDatabase(
    self: *Database,
    path: []const u8,
    io: std.Io,
) !void {
    if (self.status.package_cache_loaded) return error.DatabaseAlreadyLoaded;
    const allocator = self.arena.allocator();

    var root_dir = try std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer root_dir.close(io);

    var iterator = root_dir.iterate();

    while (try iterator.next(io)) |entry| {
        // Only consider top-level directories.
        if (entry.kind != .directory and entry.kind != .unknown) continue;

        var package_dir = root_dir.openDir(io, entry.name, .{}) catch |err| switch (err) {
            error.NotDir => continue,
            else => return err,
        };
        defer package_dir.close(io);

        // Look for "desc" inside this directory.
        const contents = package_dir.readFileAlloc(
            io,
            "desc",
            allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("package directory {s} has no desc file", .{entry.name});
                continue;
            },
            else => {
                std.log.warn("could not read {s}/desc: {}", .{ entry.name, err });
                continue;
            },
        };

        // The arena retains contents because Package fields borrow slices from it.
        var parsed = parseDescription(allocator, contents) catch |err| {
            std.log.warn("could not parse {s}/desc: {}", .{ entry.name, err });
            continue;
        };
        defer parsed.deinit(allocator);

        const package = parsed.intoPackage(allocator, self.name) catch |err| {
            std.log.warn("could not create package from {s}/desc: {}", .{ entry.name, err });
            continue;
        };

        if (!entryMatchesPackage(entry.name, package)) {
            std.log.warn(
                "local database entry {s} does not match {s}-{s}",
                .{ entry.name, package.name, package.version.raw },
            );
            continue;
        }
        if (self.packages.by_name.contains(package.name)) {
            std.log.warn("duplicate local database package: {s}", .{package.name});
            continue;
        }

        const package_id: PackageId = @enumFromInt(
            @as(u32, @intCast(self.packages.packages.items.len)),
        );
        try self.packages.packages.append(allocator, package);
        try self.packages.by_name.put(allocator, package.name, package_id);
        try self.packages.ordered.append(allocator, package_id);
    }

    try self.buildGroupIndex(allocator);
    self.status.markValid();
    self.status.package_cache_loaded = true;
    self.status.group_cache_loaded = true;
}

fn entryMatchesPackage(entry_name: []const u8, package: Package) bool {
    const separator_index = package.name.len;
    return entry_name.len == package.name.len + 1 + package.version.raw.len and
        std.mem.eql(u8, entry_name[0..separator_index], package.name) and
        entry_name[separator_index] == '-' and
        std.mem.eql(u8, entry_name[separator_index + 1 ..], package.version.raw);
}

fn buildGroupIndex(self: *Database, allocator: std.mem.Allocator) !void {
    for (self.packages.packages.items) |*package| {
        for (package.groups) |group_name| {
            const group_id = self.groups.by_name.get(group_name) orelse create: {
                const id: GroupId = @enumFromInt(
                    @as(u32, @intCast(self.groups.groups.items.len)),
                );
                try self.groups.groups.append(allocator, .{
                    .name = group_name,
                    .packages = .empty,
                });
                try self.groups.by_name.put(allocator, group_name, id);
                try self.groups.ordered.append(allocator, id);
                break :create id;
            };
            try self.groups.groups.items[@intFromEnum(group_id)].packages.append(allocator, package);
        }
    }
}

fn parseDescription(
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
                    return error.InvalidInstallReason;
            },

            .validation => {
                if (std.mem.eql(u8, line, "none")) {
                    result.validation.none = true;
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

fn freeStrings(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList([]u8),
) void {
    for (strings.items) |string| {
        allocator.free(string);
    }
    strings.deinit(allocator);
    strings.* = .empty;
}

fn descSectionFromHeader(header: []const u8) DescSection {
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

    if (std.mem.eql(u8, header, "%XDATA%"))
        return .xdata;

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

const DescSection = enum {
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
};

test "parseDescription parses a local database desc entry" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\1.2.3-4
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%INSTALLED_DB%
        \\extra
        \\
        \\%SIZE%
        \\4096
        \\
        \\%REASON%
        \\1
        \\
        \\%DEPENDS%
        \\glibc>=2.39
        \\
        \\%OPTDEPENDS%
        \\docs: documentation support
        \\
        \\%XDATA%
        \\pkgtype=pkg
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("demo", parsed.name.?);
    try std.testing.expectEqualStrings("extra", parsed.installed_database.?);
    try std.testing.expectEqualStrings("glibc>=2.39", parsed.depends.items[0]);

    const package = try parsed.intoPackage(allocator, "local");
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("extra", package.installed_database.?);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
}

test "parseDescription covers every supported local database field" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\2:1.2.3-4
        \\
        \\%BASE%
        \\demo-base
        \\
        \\%DESC%
        \\A complete parser fixture
        \\
        \\%GROUPS%
        \\base
        \\tools
        \\
        \\%URL%
        \\https://example.test/demo
        \\
        \\%LICENSE%
        \\MIT
        \\Apache-2.0
        \\
        \\%ARCH%
        \\x86_64
        \\
        \\%BUILDDATE%
        \\1700000000
        \\
        \\%INSTALLDATE%
        \\1700000100
        \\
        \\%PACKAGER%
        \\Shelly Tests <tests@example.test>
        \\
        \\%INSTALLED_DB%
        \\extra
        \\
        \\%SIZE%
        \\8192
        \\
        \\%REASON%
        \\0
        \\
        \\%VALIDATION%
        \\none
        \\sha256
        \\pgp
        \\
        \\%DEPENDS%
        \\glibc>=2.39
        \\zlib
        \\
        \\%OPTDEPENDS%
        \\docs: documentation support
        \\
        \\%MAKEDEPENDS%
        \\cmake>=3
        \\
        \\%CHECKDEPENDS%
        \\pytest
        \\
        \\%CONFLICTS%
        \\demo-old<2
        \\
        \\%PROVIDES%
        \\virtual-demo=2:1.2.3
        \\
        \\%REPLACES%
        \\old-demo<=1
        \\
        \\%XDATA%
        \\pkgtype=pkg
        \\detail=value=containing=equals
        \\
        \\%FUTURE_FIELD%
        \\ignored value
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("demo", parsed.name.?);
    try std.testing.expectEqualStrings("2:1.2.3-4", parsed.version.?);
    try std.testing.expectEqualStrings("demo-base", parsed.base.?);
    try std.testing.expectEqualStrings("A complete parser fixture", parsed.description.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.licenses.items.len);
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.build_date.?);
    try std.testing.expectEqual(@as(i64, 1700000100), parsed.install_date.?);
    try std.testing.expectEqual(@as(u64, 8192), parsed.installed_size.?);
    try std.testing.expect(parsed.validation.none);
    try std.testing.expect(parsed.validation.sha256);
    try std.testing.expect(parsed.validation.pgp);
    try std.testing.expectEqual(@as(usize, 2), parsed.xdata.items.len);
    try std.testing.expectEqualStrings("value=containing=equals", parsed.xdata.items[1].value);

    const package = try parsed.intoPackage(allocator, "local");
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqual(@as(u64, 2), package.version.epoch);
    try std.testing.expectEqualStrings("1.2.3", package.version.pkgver);
    try std.testing.expectEqualStrings("4", package.version.pkgrel.?);
    try std.testing.expectEqualStrings("extra", package.installed_database.?);
    try std.testing.expectEqual(Package.InstallReason.explicit, package.install_reason.?);
    try std.testing.expectEqualStrings("https://example.test/demo", package.url.?);
    try std.testing.expectEqualStrings("x86_64", package.architecture.?);
    try std.testing.expectEqualStrings("Shelly Tests <tests@example.test>", package.packager.?);
    try std.testing.expectEqualStrings("MIT", package.licenses[0]);
    try std.testing.expectEqualStrings("tools", package.groups[1]);

    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    switch (package.depends[0].constraint) {
        .greater_equal => |version| try std.testing.expectEqualStrings("2.39", version.raw),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("zlib", package.depends[1].name);
    try std.testing.expect(package.depends[1].constraint == .any);
    try std.testing.expectEqualStrings("documentation support", package.optional_depends[0].description.?);
    try std.testing.expectEqualStrings("cmake", package.make_depends[0].name);
    try std.testing.expectEqualStrings("pytest", package.check_depends[0].name);
    try std.testing.expectEqualStrings("demo-old", package.conflicts[0].name);
    try std.testing.expectEqualStrings("virtual-demo", package.provides[0].name);
    switch (package.provides[0].constraint) {
        .equal => |version| try std.testing.expectEqual(@as(u64, 2), version.epoch),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("old-demo", package.replaces[0].name);
}

test "parseDescription accepts CRLF and ignores unknown sections" {
    const contents =
        "%NAME%\r\ndemo\r\n\r\n" ++
        "%UNKNOWN%\r\nignored\r\n\r\n" ++
        "%VERSION%\r\n1.0-1\r\n";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try parseDescription(allocator, contents);
    defer parsed.deinit(allocator);
    const package = try parsed.intoPackage(allocator, "local");

    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqual(@as(u64, 0), package.version.epoch);
    try std.testing.expectEqualStrings("1.0", package.version.pkgver);
    try std.testing.expectEqualStrings("1", package.version.pkgrel.?);
}

test "parseDescription rejects malformed scalar values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        error.ValueOutsideSection,
        parseDescription(allocator, "orphan value\n"),
    );
    try std.testing.expectError(
        error.DuplicateValue,
        parseDescription(allocator, "%NAME%\ndemo\nduplicate\n"),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        parseDescription(allocator, "%BUILDDATE%\nnot-a-number\n"),
    );
    try std.testing.expectError(
        error.InvalidInstallReason,
        parseDescription(allocator, "%REASON%\n9\n"),
    );
    try std.testing.expectError(
        error.InvalidXData,
        parseDescription(allocator, "%XDATA%\nmissing-equals\n"),
    );
}

test "ParsedDescription requires package identity and valid relations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var missing_name = try parseDescription(allocator, "%VERSION%\n1.0-1\n");
    defer missing_name.deinit(allocator);
    try std.testing.expectError(
        error.MissingPackageName,
        missing_name.intoPackage(allocator, "local"),
    );

    var missing_version = try parseDescription(allocator, "%NAME%\ndemo\n");
    defer missing_version.deinit(allocator);
    try std.testing.expectError(
        error.MissingPackageVersion,
        missing_version.intoPackage(allocator, "local"),
    );

    var invalid_relation = try parseDescription(
        allocator,
        "%NAME%\ndemo\n\n%VERSION%\n1.0-1\n\n%DEPENDS%\n>=2\n",
    );
    defer invalid_relation.deinit(allocator);
    try std.testing.expectError(
        error.InvalidPackageRelation,
        invalid_relation.intoPackage(allocator, "local"),
    );
}

test "loadDatabase owns and indexes parsed packages" {
    const contents =
        \\%NAME%
        \\demo
        \\
        \\%VERSION%
        \\1.2.3-4
        \\
        \\%DESC%
        \\Demo package
        \\
        \\%GROUPS%
        \\base
        \\
        \\%DEPENDS%
        \\glibc
    ;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "demo-1.2.3-4", .default_dir);
    var package_dir = try temporary.dir.openDir(std.testing.io, "demo-1.2.3-4", .{});
    defer package_dir.close(std.testing.io);
    try package_dir.writeFile(std.testing.io, .{
        .sub_path = "desc",
        .data = contents,
    });

    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var database = try Database.init(std.testing.allocator, "local", path);
    defer database.deinit();
    try database.loadDatabase(path, std.testing.io);

    try std.testing.expect(database.status.package_cache_loaded);
    try std.testing.expectEqual(@as(usize, 1), database.packages.packages.items.len);
    const package_id = database.packages.by_name.get("demo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(package_id));
    const package = database.packages.packages.items[@intFromEnum(package_id)];
    try std.testing.expectEqualStrings("demo", package.name);
    try std.testing.expectEqualStrings("1.2.3-4", package.version.raw);
    try std.testing.expectEqualStrings("glibc", package.depends[0].name);
    const group_id = database.groups.by_name.get("base") orelse return error.TestUnexpectedResult;
    const group = database.groups.groups.items[@intFromEnum(group_id)];
    try std.testing.expectEqual(@as(usize, 1), group.packages.items.len);
    try std.testing.expectEqualStrings("demo", group.packages.items[0].name);
    try std.testing.expectError(
        error.DatabaseAlreadyLoaded,
        database.loadDatabase(path, std.testing.io),
    );
}

test "loadDatabase skips missing and malformed package descriptions" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    try temporary.dir.createDir(std.testing.io, "valid-1.0-1", .default_dir);
    try temporary.dir.createDir(std.testing.io, "malformed-1.0-1", .default_dir);
    try temporary.dir.createDir(std.testing.io, "missing-1.0-1", .default_dir);

    {
        var valid_dir = try temporary.dir.openDir(std.testing.io, "valid-1.0-1", .{});
        defer valid_dir.close(std.testing.io);
        try valid_dir.writeFile(std.testing.io, .{
            .sub_path = "desc",
            .data = "%NAME%\nvalid\n\n%VERSION%\n1.0-1\n",
        });
    }
    {
        var malformed_dir = try temporary.dir.openDir(std.testing.io, "malformed-1.0-1", .{});
        defer malformed_dir.close(std.testing.io);
        try malformed_dir.writeFile(std.testing.io, .{
            .sub_path = "desc",
            .data = "%NAME%\nmalformed\n",
        });
    }

    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var database = try Database.init(std.testing.allocator, "local", path);
    defer database.deinit();
    try database.loadDatabase(path, std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), database.packages.packages.items.len);
    try std.testing.expect(database.packages.by_name.contains("valid"));
    try std.testing.expect(!database.packages.by_name.contains("malformed"));
    try std.testing.expect(!database.packages.by_name.contains("missing"));
}

test "freeStrings frees each string and the list storage" {
    const allocator = std.testing.allocator;
    var strings: std.ArrayList([]u8) = .empty;
    defer {
        for (strings.items) |string| allocator.free(string);
        strings.deinit(allocator);
    }

    const first = try allocator.dupe(u8, "https://mirror-one.example");
    strings.append(allocator, first) catch |err| {
        allocator.free(first);
        return err;
    };

    const second = try allocator.dupe(u8, "https://mirror-two.example");
    strings.append(allocator, second) catch |err| {
        allocator.free(second);
        return err;
    };

    freeStrings(allocator, &strings);

    try std.testing.expectEqual(@as(usize, 0), strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), strings.capacity);
}
