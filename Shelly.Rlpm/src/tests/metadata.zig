const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("archive_fixture.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;
const Value = std.json.Value;

fn reference() !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, allocator, @embedFile("fixtures/metadata-reference.json"), .{});
}

fn equalOptional(expected: Value, actual: ?[]const u8) !void {
    if (expected == .null)
        try std.testing.expect(actual == null)
    else
        try std.testing.expectEqualStrings(
            expected.string,
            actual.?,
        );
}

test "relations and formatting match independent libalpm fixtures" {
    const recorded = try reference();
    defer recorded.deinit();
    for (recorded.value.object.get("relations").?.array.items) |item| {
        const expected = item.object;
        const relation = try rlpm.PackageRelation.parse(expected.get("input").?.string);
        try std.testing.expectEqualStrings(expected.get("name").?.string, relation.name);
        try equalOptional(expected.get("description").?, relation.description);
        const mod: i64 = switch (relation.constraint) {
            .any => 1,
            .equal => 2,
            .greater_equal => 3,
            .less_equal => 4,
            .greater => 5,
            .less => 6,
        };
        try std.testing.expectEqual(expected.get("mod").?.integer, mod);
        switch (relation.constraint) {
            .any => try std.testing.expect(expected.get("version").? == .null),
            inline else => |version| try std.testing.expectEqualStrings(
                expected.get("version").?.string,
                version,
            ),
        }
        const formatted = try relation.formatAlloc(allocator);
        defer allocator.free(formatted);
        try std.testing.expectEqualStrings(expected.get("formatted").?.string, formatted);
        const reparsed = try rlpm.PackageRelation.parse(formatted);
        try std.testing.expectEqualStrings(relation.name, reparsed.name);
        try std.testing.expectEqual(
            std.meta.activeTag(relation.constraint),
            std.meta.activeTag(reparsed.constraint),
        );
    }
}

test "raw version comparisons preserve byte inputs under C locale" {
    const recorded = try reference();
    defer recorded.deinit();
    for (recorded.value.object.get("byte_versions").?.array.items) |item| {
        const expected = item.object;
        const a_hex = expected.get("a").?.string;
        const b_hex = expected.get("b").?.string;
        const a = try allocator.alloc(u8, a_hex.len / 2);
        defer allocator.free(a);
        const b = try allocator.alloc(u8, b_hex.len / 2);
        defer allocator.free(b);
        _ = try std.fmt.hexToBytes(a, a_hex);
        _ = try std.fmt.hexToBytes(b, b_hex);
        try std.testing.expectEqual(
            expected.get("sign").?.integer,
            @intFromEnum(rlpm.Version.compareStrings(a, b)),
        );
        try std.testing.expectEqual(
            -expected.get("sign").?.integer,
            @intFromEnum(rlpm.Version.compareStrings(b, a)),
        );
    }
}

fn entriesFromJson(arena: *std.heap.ArenaAllocator, values: []const Value) ![]Fixture.Entry {
    const owned = arena.allocator();
    const entries = try owned.alloc(Fixture.Entry, values.len);
    for (values, entries) |value, *entry| {
        const object = value.object;
        entry.* = .{
            .path = object.get("path").?.string,
            .contents = object.get("contents").?.string,
            .kind = std.meta.stringToEnum(@FieldType(Fixture.Entry, "kind"), object.get("kind").?.string).?,
            .target = if (object.get("target")) |target| target.string else null,
        };
    }
    return entries;
}

test "archive modes, duplicate metadata, mtree inventory and provisions match libalpm" {
    const recorded = try reference();
    defer recorded.deinit();
    const manifest = try std.json.parseFromSlice(Value, allocator, @embedFile("reference/manifest.json"), .{});
    defer manifest.deinit();
    try std.testing.expectEqualStrings(
        manifest.value.object.get("library").?.object.get("sha256").?.string,
        recorded.value.object.get("library_sha256").?.string,
    );
    inline for (.{
        .{ "relations", 25 },
        .{ "byte_versions", 9 },
        .{ "archives", 18 },
        .{ "satisfaction", 13 },
        .{ "signatures", 6 },
        .{ "reasons", 5 },
    }) |coverage| {
        try std.testing.expectEqual(coverage[1], recorded.value.object.get(coverage[0]).?.array.items.len);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (recorded.value.object.get("archives").?.array.items) |value| {
        const case = value.object;
        const entries = try entriesFromJson(&arena, case.get("entries").?.array.items);
        var fixture = try Fixture.init(entries, .none);
        defer fixture.deinit();
        if (case.get("truncate")) |truncate| {
            const contents = try fixture.temporary.dir.readFileAlloc(
                io,
                "package.tar",
                allocator,
                .limited(65536),
            );
            defer allocator.free(contents);
            try fixture.temporary.dir.writeFile(
                io,
                .{
                    .sub_path = "package.tar",
                    .data = contents[0..@intCast(truncate.integer)],
                },
            );
        }
        for (case.get("results").?.array.items) |result| {
            const expected = result.object;
            const full = expected.get("full").?.bool;
            const loaded = rlpm.Package.loadArchive(
                allocator,
                fixture.path,
                .{ .mode = if (full) .full else .metadata },
            );
            if (!expected.get("success").?.bool) {
                if (loaded) |unexpected| {
                    var package = unexpected;
                    package.deinit();
                    return error.UnexpectedPackageSuccess;
                } else |err| {
                    if (expected.contains("reference_signal"))
                        try std.testing.expectEqual(
                            error.InvalidMtree,
                            err,
                        );
                    switch (err) {
                        error.InvalidVersion,
                        error.InvalidPackageName,
                        error.MissingPackageName,
                        error.MissingPackageVersion,
                        error.InvalidPkginfo,
                        error.ArchiveFailed,
                        error.InvalidMtree,
                        => {},
                        else => return err,
                    }
                }
                continue;
            }
            var package = try loaded;
            defer package.deinit();
            try std.testing.expectEqual(.archive, package.origin);
            try std.testing.expectEqualStrings(fixture.path, package.archive_path.?);
            try std.testing.expect(package.repository_filename == null);
            try std.testing.expectEqualStrings(expected.get("name").?.string, package.name);
            try std.testing.expectEqualStrings(expected.get("version").?.string, package.version.raw);
            try equalOptional(expected.get("desc").?, package.description);
            try equalOptional(expected.get("installed_db").?, package.installed_database);
            try std.testing.expectEqual(expected.get("scriptlet").?.bool, package.has_scriptlet);
            try std.testing.expect(package.validation.none);
            try std.testing.expectEqual(
                expected.get("reason").?.integer,
                @intFromEnum(package.install_reason.?),
            );
            try std.testing.expectEqual(full, package.files_loaded);
            const stat = try fixture.temporary.dir.statFile(io, "package.tar", .{});
            try std.testing.expectEqual(stat.size, package.compressed_size.?);
            try std.testing.expectEqual(0, package.download_size.?);
            const files = expected.get("files").?.array.items;
            try std.testing.expectEqual(files.len, package.files.len);
            for (files, package.files) |file, actual| {
                try std.testing.expectEqualStrings(file.object.get("name").?.string, actual.name);
                try std.testing.expectEqual(
                    @as(u64, @intCast(file.object.get("size").?.integer)),
                    actual.size.?,
                );
                try std.testing.expectEqual(file.object.get("mode").?.integer, actual.mode.?);
                try std.testing.expect(package.findFile(actual.name) != null);
            }
            try std.testing.expect(package.findFile("not-present") == null);
            const backups = expected.get("backups").?.array.items;
            try std.testing.expectEqual(backups.len, package.backups.len);
            for (backups, package.backups) |backup, actual| {
                try std.testing.expectEqualStrings(backup.object.get("name").?.string, actual.name);
                try equalOptional(backup.object.get("hash").?, actual.hash);
            }
            if (std.mem.eql(u8, case.get("name").?.string, "plain") and full) {
                for (recorded.value.object.get("satisfaction").?.array.items) |expectation| {
                    const data = expectation.object;
                    try std.testing.expectEqual(
                        data.get("matched").?.bool,
                        package.satisfies(
                            try rlpm.PackageRelation.parse(
                                data.get("requirement").?.string,
                            ),
                        ),
                    );
                }
                try std.testing.expectEqual(.symlink, package.findFile("usr/bin/link").?.kind);
                try std.testing.expectEqualStrings("demo", package.findFile("usr/bin/link").?.link_target.?);
                try std.testing.expectEqual(.hardlink, package.findFile("usr/bin/hard").?.kind);
            }
        }
    }
}

const desc = "%NAME%\ndemo\n\n%VERSION%\nalpha:1.0-\n\n%BASE%\ndemo-base\n\n%DESC%\nDescription\n\n%FILENAME%\ndemo.pkg.tar.zst\n\n%CSIZE%\n123\n\n%ISIZE%\n456\n\n%MD5SUM%\n0123456789abcdef0123456789abcdef\n\n%SHA256SUM%\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n\n%PGPSIG%\nAAECA/8=\n\n%VALIDATION%\nmd5\nsha256\npgp\n\n%INSTALLED_DB%\nremoved-cachyos-repo\n\n%FILES%\nzeta\netc/\netc/demo.conf\n\n%BACKUP%\netc/demo.conf\t00000000000000000000000000000000\n\n%DEPENDS%\nfoo>1<2: ordinary description\n\n%PROVIDES%\nvirtual=\n\n%XDATA%\ncustom=a=b\n\n";

test "normalized local and sync metadata own fields, files, hashes and CachyOS provenance" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const package = blk: {
        const input = try allocator.dupe(u8, desc);
        defer allocator.free(input);
        var parsed = try rlpm.ParsedDescription.parse(allocator, input);
        defer parsed.deinit(allocator);
        break :blk try parsed.intoPackage(&arena, .{ .origin = .sync, .database_name = "current-repo" });
    };
    try std.testing.expectEqual(.sync, package.origin);
    try std.testing.expectEqualStrings("current-repo", package.database_name);
    try std.testing.expectEqualStrings("removed-cachyos-repo", package.installed_database.?);
    try std.testing.expectEqualStrings("demo.pkg.tar.zst", package.repository_filename.?);
    try std.testing.expect(package.archive_path == null and package.download_size == null);
    try std.testing.expectEqual(123, package.compressed_size.?);
    try std.testing.expectEqual(456, package.installed_size.?);
    try std.testing.expect(package.validation.md5 and package.validation.sha256 and package.validation.pgp);
    try std.testing.expectEqual(32, package.md5_sum.?.len);
    try std.testing.expectEqual(64, package.sha256_sum.?.len);
    const signature = (try package.decodeSignature(allocator)).?;
    defer allocator.free(signature);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 255 }, signature);
    try std.testing.expectEqualStrings("etc/", package.files[0].name);
    try std.testing.expect(package.files[0].size == null and package.files[0].mode == null);
    try std.testing.expectEqualStrings("00000000000000000000000000000000", package.backups[0].hash.?);
    try std.testing.expectEqualStrings("foo>1", package.depends[0].name);
    try std.testing.expectEqualStrings("ordinary description", package.depends[0].description.?);
    try std.testing.expectEqualStrings("", package.provides[0].constraint.equal);
    var minimal: rlpm.ParsedDescription = .{ .name = "demo", .version = "1" };
    defer minimal.deinit(allocator);
    const local = try minimal.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try std.testing.expect(local.installed_database == null);
    try std.testing.expect(!local.files_loaded);
}

const pkginfo = "pkgname = demo\npkgver = 1.0-1\nbackup = etc/demo.conf\ndepend = foo>=alpha:1.0\n";
const mtree = "#mtree\n./.INSTALL type=file mode=644 size=5\n./etc type=dir mode=755\n./etc/demo.conf type=file mode=644 size=4\n./link type=link mode=777 link=etc/demo.conf\n";
const stream_entries = [_]Fixture.Entry{
    .{ .path = ".PKGINFO", .contents = pkginfo },
    .{ .path = ".CHANGELOG", .contents = "first changelog\n" },
    .{ .path = ".CHANGELOG", .contents = "second changelog\n" },
    .{ .path = ".MTREE", .contents = mtree },
    .{ .path = ".INSTALL", .contents = "shell" },
    .{ .path = "etc/demo.conf", .contents = "data" },
};

test "compressed archive streams and mtree iterators own independent lifetimes" {
    for ([_]Fixture.Compression{ .none, .zstd, .gzip, .xz, .bzip2 }) |compression| {
        var fixture = try Fixture.init(&stream_entries, compression);
        defer fixture.deinit();
        var package = try rlpm.Package.loadArchive(allocator, fixture.path, .{ .mode = .full });
        var released = false;
        defer if (!released) package.deinit();
        try std.testing.expectEqual(.mtree, package.files_source);
        var changelog = (try package.openMember(allocator, .changelog)).?;
        defer changelog.deinit();
        var install = (try package.openMember(allocator, .install)).?;
        defer install.deinit();
        var iterator = (try package.openMtree(allocator)).?;
        defer iterator.deinit();
        package.deinit();
        released = true;
        const history = try changelog.readAll(allocator, 1024);
        defer allocator.free(history);
        try std.testing.expectEqualStrings("first changelog\n", history);
        const script = try install.readAll(allocator, 1024);
        defer allocator.free(script);
        try std.testing.expectEqualStrings("shell", script);
        var count: usize = 0;
        while (try iterator.next()) |file| {
            count += 1;
            if (std.mem.eql(u8, file.name, "link")) {
                try std.testing.expectEqual(.symlink, file.kind);
                try std.testing.expectEqualStrings("etc/demo.conf", file.link_target.?);
            }
        }
        try std.testing.expectEqual(4, count);
    }
}

fn allocationConversion(failing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(failing);
    defer arena.deinit();
    var parsed = try rlpm.ParsedDescription.parse(failing, desc);
    defer parsed.deinit(failing);
    const package = try parsed.intoPackage(&arena, .{ .origin = .sync, .database_name = "cachyos" });
    const signature = (try package.decodeSignature(failing)).?;
    defer failing.free(signature);
}

fn allocationArchive(failing: std.mem.Allocator, path: []const u8) !void {
    var package = try rlpm.Package.loadArchive(failing, path, .{ .mode = .full });
    defer package.deinit();
    var changelog = (try package.openMember(failing, .changelog)).?;
    defer changelog.deinit();
    const contents = try changelog.readAll(failing, 1024);
    defer failing.free(contents);
    var mtree_iterator = (try package.openMtree(failing)).?;
    defer mtree_iterator.deinit();
    while (try mtree_iterator.next()) |_| {}
}

test "conversion, full archive and stream operations clean up every failed allocation" {
    try std.testing.checkAllAllocationFailures(allocator, allocationConversion, .{});
    var fixture = try Fixture.init(&stream_entries, .zstd);
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(allocator, allocationArchive, .{fixture.path});
}

test "signature decoding and local file metadata match independent captures" {
    const recorded = try reference();
    defer recorded.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (recorded.value.object.get("reasons").?.array.items) |reason| {
        const input = try std.fmt.allocPrint(
            allocator,
            "%REASON%\n{s}\n",
            .{reason.object.get("input").?.string},
        );
        defer allocator.free(input);
        var parsed_reason = try rlpm.ParsedDescription.parse(allocator, input);
        defer parsed_reason.deinit(allocator);
        try std.testing.expectEqual(
            reason.object.get("reason").?.integer,
            @intFromEnum(parsed_reason.reason.?),
        );
    }
    const expected = recorded.value.object.get("local_metadata").?.object;
    const input = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{
            expected.get("desc").?.string,
            expected.get("files_input").?.string,
        },
    );
    defer allocator.free(input);
    var parsed = try rlpm.ParsedDescription.parse(allocator, input);
    defer parsed.deinit(allocator);
    var package = try parsed.intoPackage(&arena, .{ .origin = .local, .database_name = "local" });
    try equalOptional(expected.get("installed_db").?, package.installed_database);
    try std.testing.expectEqual(.local, package.origin);
    try std.testing.expectEqual(
        @as(u64, @intCast(expected.get("installed_size").?.integer)),
        package.installed_size.?,
    );
    try std.testing.expectEqual(14, expected.get("validation").?.integer);
    try std.testing.expect(package.validation.md5 and package.validation.sha256 and package.validation.pgp);
    try std.testing.expect(!package.validation.none);
    try std.testing.expectEqual(.database, package.files_source);
    for (expected.get("files").?.array.items, package.files) |file, actual|
        try std.testing.expectEqualStrings(
            file.string,
            actual.name,
        );
    const backup = expected.get("backup").?.object;
    try std.testing.expectEqualStrings(backup.get("name").?.string, package.backups[0].name);
    try equalOptional(backup.get("hash").?, package.backups[0].hash);
    try std.testing.expect(try package.decodeSignature(allocator) == null);
    for (recorded.value.object.get("signatures").?.array.items) |case| {
        const signature = case.object;
        package.base64_signature = signature.get("encoded").?.string;
        const decoded = package.decodeSignature(allocator);
        if (signature.get("success").?.bool) {
            const bytes = (try decoded).?;
            defer allocator.free(bytes);
            const hex = try std.fmt.allocPrint(allocator, "{x}", .{bytes});
            defer allocator.free(hex);
            try std.testing.expectEqualStrings(signature.get("decoded").?.string, hex);
        } else {
            if (decoded) |unexpected| {
                if (unexpected) |bytes| allocator.free(bytes);
                return error.UnexpectedSignatureDecode;
            } else |err| switch (err) {
                error.InvalidCharacter, error.InvalidPadding => {},
                else => return err,
            }
        }
    }
    try std.testing.expectError(error.UnsupportedPackageOrigin, package.openMember(allocator, .changelog));
}

test "compressed mtree data, absent streams and bounded metadata errors" {
    const compressed = try Fixture.gzip(mtree);
    defer allocator.free(compressed);
    var entries = stream_entries;
    entries[3].contents = compressed;
    var fixture = try Fixture.init(&entries, .zstd);
    defer fixture.deinit();
    var package = try rlpm.Package.loadArchive(allocator, fixture.path, .{ .mode = .full });
    defer package.deinit();
    try std.testing.expectEqual(.mtree, package.files_source);
    try std.testing.expectEqual(3, package.files.len);
    var iterator = (try package.openMtree(allocator)).?;
    defer iterator.deinit();
    var count: usize = 0;
    while (try iterator.next()) |_|
        count += 1;
    try std.testing.expectEqual(4, count);
    var stream = (try package.openMember(allocator, .changelog)).?;
    defer stream.deinit();
    try std.testing.expectError(error.MetadataTooLarge, stream.readAll(allocator, 3));
    var absent = try Fixture.init(&.{.{ .path = ".PKGINFO", .contents = pkginfo }}, .none);
    defer absent.deinit();
    var minimal = try rlpm.Package.loadArchive(allocator, absent.path, .{});
    defer minimal.deinit();
    try std.testing.expect(try minimal.openMember(allocator, .changelog) == null);
    try std.testing.expect(try minimal.openMtree(allocator) == null);
    try std.testing.expectEqual(.absent, minimal.members.changelog);
    var oversized = try Fixture.init(&.{.{ .path = ".PKGINFO", .declared_size = (1 << 20) + 1 }}, .zstd);
    defer oversized.deinit();
    try std.testing.expectError(
        error.PkginfoTooLarge,
        rlpm.Package.loadArchive(
            allocator,
            oversized.path,
            .{ .mode = .full },
        ),
    );
    const long_line = try allocator.alloc(u8, 512 * 1024 + 1);
    defer allocator.free(long_line);
    @memset(long_line, 'a');
    var line_fixture = try Fixture.init(&.{.{ .path = ".PKGINFO", .contents = long_line }}, .zstd);
    defer line_fixture.deinit();
    try std.testing.expectError(
        error.MetadataLineTooLong,
        rlpm.Package.loadArchive(
            allocator,
            line_fixture.path,
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidBackup,
        rlpm.ParsedDescription.parse(
            allocator,
            "%BACKUP%\nmissing-tab\n",
        ),
    );
}

test "Owner copies permissive assumed-installed relations and rejects embedded NUL" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const relations = [_]rlpm.PackageRelation{
        try .parse("foo=alpha:1.0: description"),
        try .parse("empty="),
        try .parse(""),
    };
    var owner = try rlpm.Owner.init(
        io,
        allocator,
        .{
            .root = path,
            .database_path = path,
            .assume_installed = &relations,
        },
        &.{},
    );
    defer owner.deinit() catch unreachable;
    try std.testing.expectEqualStrings("alpha:1.0", owner.options().assume_installed[0].constraint.equal);
    try std.testing.expectEqualStrings("", owner.options().assume_installed[1].constraint.equal);
    var update = owner.options();
    update.assume_installed = &.{.{ .name = "bad", .constraint = .{ .equal = "1\x00two" } }};
    try std.testing.expectError(error.InvalidPackageRelation, owner.setOptions(io, update));
    try std.testing.expectEqual(3, owner.options().assume_installed.len);
    // The resolver consumes assumed entries as provisions, so only ANY/EQ are legal.
    update.assume_installed = &.{try .parse("foo>=alpha:1.0")};
    try std.testing.expectError(error.InvalidOption, owner.setOptions(io, update));
    try std.testing.expectEqual(3, owner.options().assume_installed.len);
}
