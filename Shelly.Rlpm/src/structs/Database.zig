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
    groups: std.ArrayList(Group),
    by_name: std.StringHashMap(GroupId),
    ordered: std.ArrayList(GroupId),
};

pub const PackageIndex = struct {
    packages: std.ArrayList(Package),
    by_name: std.StringHashMapUnmanaged(PackageId),
    ordered: std.ArrayList(PackageId),
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

pub fn deinit(
    self: *Database,
    allocator: std.mem.Allocator,
) void {
    allocator.free(self.tree_name);
    if (self.path) |path| allocator.free(path);

    self.packages.deinit(allocator);
    self.groups.deinit(allocator);

    freeStrings(allocator, &self.cache_servers);
    freeStrings(allocator, &self.servers);

    self.* = undefined;
}

pub fn loadDatabase(
    self: *Database,
    path: []const u8,
    io: std.Io,
) !void {
    var root_dir = try std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
        .access_sub_paths = true,
    });
    defer root_dir.close(io);

    var iterator = root_dir.iterate();

    while (try iterator.next(io)) |entry| {
        // Only consider top-level directories.
        if (entry.kind != .directory) continue;

        var package_dir = try root_dir.openDir(io, entry.name, .{});
        defer package_dir.close(io);

        // Look for "desc" inside this directory.
        const contents = package_dir.readFileAlloc(
            io,
            "desc",
            self.allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            // This directory has no desc file.
            error.FileNotFound => continue,
            else => return err,
        };
        defer self.allocator.free(contents);

        std.debug.print("package directory: {s}\n", .{entry.name});
        std.debug.print("desc contents:\n{s}\n", .{contents});

        // Parse `contents` here.
    }
}

fn parseDescription(
    allocator: std.mem.Allocator,
    contents: []const u8,
) !ParsedDescription {
    var result: Package = .{
        .allocator = allocator,
    };
    errdefer result.deinit();

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
