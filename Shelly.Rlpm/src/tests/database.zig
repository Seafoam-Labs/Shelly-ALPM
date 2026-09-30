//! Database public-consumer tests. All filesystem state and SQLite images are private.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});
const allocator = std.testing.allocator;
const io = std.testing.io;
const Value = std.json.Value;

const Fixture = struct {
    temporary: std.testing.TmpDir,
    root: [:0]u8,
    db: [:0]u8,

    fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        try temporary.dir.createDirPath(io, "root");
        try temporary.dir.createDirPath(io, "db/sync");
        const root = try temporary.dir.realPathFileAlloc(io, "root", allocator);
        errdefer allocator.free(root);
        const db = try temporary.dir.realPathFileAlloc(io, "db", allocator);
        return .{
            .temporary = temporary,
            .root = root,
            .db = db,
        };
    }

    fn deinit(self: *Fixture) void {
        allocator.free(self.root);
        allocator.free(self.db);
        self.temporary.cleanup();
    }

    fn config(self: Fixture) rlpm.OwnerConfiguration {
        return .{ .root = self.root, .database_path = self.db };
    }

    fn local(self: *Fixture, directory: []const u8, contents: ?[]const u8) !void {
        const path = try std.fmt.allocPrint(allocator, "db/local/{s}", .{directory});
        defer allocator.free(path);
        try self.temporary.dir.createDirPath(io, path);
        if (contents) |bytes| {
            const desc_path = try std.fmt.allocPrint(allocator, "{s}/desc", .{path});
            defer allocator.free(desc_path);
            try self.temporary.dir.writeFile(io, .{ .sub_path = desc_path, .data = bytes });
        }
    }

    fn sync(
        self: *Fixture,
        name: []const u8,
        members: []const Archive.Entry,
        compression: Archive.Compression,
        truncate: ?usize,
    ) !void {
        var archive = try Archive.init(members, compression);
        defer archive.deinit();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive.path, allocator, .limited(64 << 20));
        defer allocator.free(bytes);
        const path = try std.fmt.allocPrint(allocator, "db/sync/{s}", .{name});
        defer allocator.free(path);
        try self.temporary.dir.writeFile(
            io,
            .{
                .sub_path = path,
                .data = bytes[0 .. truncate orelse bytes.len],
            },
        );
    }
};

const desc = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%DESC%\nText utility\n\n%GROUPS%\nz-tools\ncommon\n\n%PROVIDES%\nvirtual=3\nplain\n\n%INSTALLED_DB%\nremoved-cachyos-repo\n\n";
const entries = [_]Archive.Entry{
    .{ .path = "demo-1-1/desc", .contents = desc },
    .{
        .path = "zeta-1-1/desc",
        .contents = "%NAME%\nzeta\n\n%VERSION%\n1-1\n\n%DESC%\ntext editor\n\n%GROUPS%\ncommon\neditors\n\n%DEPENDS%\nvirtual>=3\n\n%OPTDEPENDS%\ndemo: documentation\n\n",
    },
    .{ .path = "demo-1-1/files", .contents = "%FILES%\nz\netc/\netc/demo\n\n" },
};

fn field(value: Value, key: []const u8) Value {
    return value.object.get(key).?;
}

fn optionalString(value: Value) ?[]const u8 {
    return if (value == .null) null else value.string;
}

fn expectOptional(expected: Value, actual: ?[]const u8) !void {
    if (expected == .null)
        try std.testing.expect(actual == null)
    else
        try std.testing.expectEqualStrings(
            expected.string,
            actual orelse
                return error.TestUnexpectedResult,
        );
}

fn expectNames(
    owner: *rlpm.Owner,
    refs: []const rlpm.PackageRef,
    expected: []const []const u8,
) !void {
    try std.testing.expectEqual(expected.len, refs.len);
    for (refs, expected) |ref, name|
        try std.testing.expectEqualStrings(name, (try owner.package(ref)).name);
}

fn sqlImage(columns: []const Value, rows: []const Value) ![]u8 {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    defer _ = c.sqlite3_close(db);
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    if (columns.len == 0) {
        try sql.appendSlice(allocator, "CREATE TABLE different (value TEXT)");
    } else {
        try sql.appendSlice(allocator, "CREATE TABLE packages (");
        for (columns, 0..) |column, i| {
            if (i != 0) try sql.append(allocator, ',');
            try sql.append(allocator, '"');
            try sql.appendSlice(allocator, column.string);
            try sql.appendSlice(allocator, "\" TEXT");
        }
        try sql.append(allocator, ')');
    }
    const create = try allocator.dupeSentinel(u8, sql.items, 0);
    defer allocator.free(create);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, create, null, null, null));
    if (rows.len != 0) {
        sql.clearRetainingCapacity();
        try sql.appendSlice(allocator, "INSERT INTO packages VALUES (");
        for (columns, 0..) |_, i| {
            if (i != 0) try sql.append(allocator, ',');
            try sql.append(allocator, '?');
        }
        try sql.append(allocator, ')');
        const insert = try allocator.dupeSentinel(u8, sql.items, 0);
        defer allocator.free(insert);
        var stmt: ?*c.sqlite3_stmt = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, insert, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        for (rows) |row| {
            for (row.array.items, 1..) |value, i| {
                const status = if (value == .null)
                    c.sqlite3_bind_null(stmt, @intCast(i))
                else
                    c.sqlite3_bind_text(
                        stmt,
                        @intCast(i),
                        value.string.ptr,
                        @intCast(value.string.len),
                        null,
                    );
                try std.testing.expectEqual(c.SQLITE_OK, status);
            }
            try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt));
            try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_reset(stmt));
        }
    }
    var size: c.sqlite3_int64 = 0;
    const image = c.sqlite3_serialize(db, "main", &size, 0) orelse return error.OutOfMemory;
    defer c.sqlite3_free(image);
    return allocator.dupe(u8, image[0..@intCast(size)]);
}

test "local creation version validation and corrupt entries match pinned reference" {
    const reference = try std.json.parseFromSlice(
        Value,
        allocator,
        @embedFile("fixtures/database-reference.json"),
        .{},
    );
    defer reference.deinit();
    for (field(reference.value, "local").array.items) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        if (optionalString(field(case, "marker"))) |marker| {
            try fixture.temporary.dir.createDirPath(io, "db/local");
            try fixture.temporary.dir.writeFile(
                io,
                .{
                    .sub_path = "db/local/ALPM_DB_VERSION",
                    .data = marker,
                },
            );
        }
        for (field(case, "entries").array.items) |entry|
            try fixture.local(
                field(entry, "path").string,
                if (entry.object.get("desc")) |value|
                    value.string
                else
                    null,
            );
        const expected = field(case, "result");
        if (!field(expected, "success").bool) {
            try std.testing.expectError(
                error.UnsupportedDatabaseVersion,
                rlpm.Owner.init(
                    io,
                    allocator,
                    fixture.config(),
                    &.{},
                ),
            );
            continue;
        }
        var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{});
        defer owner.deinit() catch unreachable;
        const local = owner.localDatabase().?;
        const packages = field(expected, "packages").array.items;
        try std.testing.expectEqual(packages.len, (try owner.packageIds(local)).len);
        for (packages) |item| {
            const ref = (try owner.findPackage(local, field(item, "name").string)).?;
            try std.testing.expect(!(try owner.package(ref)).description_loaded);
            _ = owner.packageMetadata(io, ref, .{}) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            const package = try owner.package(ref);
            // Duplicate local entries use directory enumeration order, not version preference.
            if (!std.mem.eql(u8, field(case, "name").string, "duplicate"))
                try std.testing.expectEqualStrings(
                    field(item, "version").string,
                    package.version.raw,
                );
            try expectOptional(field(item, "desc"), package.description);
            const size = field(item, "isize").integer;
            if (size < 0)
                try std.testing.expect(
                    package.installed_size == null and
                        package.metadata_issues.invalid_size,
                )
            else
                try std.testing.expectEqual(
                    @as(u64, @intCast(size)),
                    package.installed_size orelse 0,
                );
            try std.testing.expectEqual(field(item, "builddate").integer, package.build_date orelse 0);
        }
        if (std.mem.eql(u8, field(case, "name").string, "duplicate") or
            std.mem.eql(
                u8,
                field(case, "name").string,
                "invalid_directory",
            ))
            try std.testing.expectEqual(
                1,
                (try owner.database(local)).skipped_entries.items.len,
            );
    }
}

test "tar and CachyOS SQLite records and regex search match pinned reference" {
    const reference = try std.json.parseFromSlice(
        Value,
        allocator,
        @embedFile("fixtures/database-reference.json"),
        .{},
    );
    defer reference.deinit();
    for (field(reference.value, "sync").array.items) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var archive_entries: std.ArrayList(Archive.Entry) = .empty;
        defer archive_entries.deinit(allocator);
        for (field(case, "entries").array.items) |entry|
            try archive_entries.append(
                allocator,
                .{
                    .path = field(entry, "path").string,
                    .contents = field(entry, "contents").string,
                },
            );
        const sqlite = if (case.object.get("columns")) |columns|
            try sqlImage(
                columns.array.items,
                field(case, "rows").array.items,
            )
        else
            null;
        defer if (sqlite) |bytes| allocator.free(bytes);
        if (sqlite) |bytes|
            try archive_entries.append(allocator, .{ .path = "pacman.db", .contents = bytes });
        try fixture.sync(
            "test.db",
            archive_entries.items,
            .none,
            if (case.object.get("truncate")) |value|
                @intCast(value.integer)
            else
                null,
        );
        var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{.{ .database_name = "test" }});
        defer owner.deinit() catch unreachable;
        const db = owner.findDatabase("test").?;
        try std.testing.expect(!(try owner.database(db)).status.package_cache_loaded);
        const expected = field(case, "result");
        const label = field(case, "name").string;
        const invalid_identity = std.mem.eql(u8, label, "sqlite_missing_identity") or
            std.mem.eql(
                u8,
                label,
                "sqlite_null_identity",
            );
        if (!field(expected, "success").bool or invalid_identity) {
            if (owner.loadDatabase(io, db)) |_|
                return error.ExpectedCorruptDatabase
            else |err|
                try std.testing.expect(err != error.OutOfMemory);
            try std.testing.expectEqual(.invalid, (try owner.database(db)).status.validation);
            try std.testing.expectEqual(0, (try owner.database(db)).packages.by_name.count());
            continue;
        }
        try owner.ensureDatabase(io, db);
        const actual_format = (try owner.database(db)).backend.sync.format;
        const expected_format: @TypeOf(actual_format) = if (sqlite != null) .sqlite else .tar;
        try std.testing.expectEqual(expected_format, actual_format);
        const packages = field(expected, "packages").array.items;
        try std.testing.expectEqual(packages.len, (try owner.packageIds(db)).len);
        for (packages, try owner.packageIds(db)) |item, id| {
            const package = try owner.package(try owner.packageReference(db, id));
            try std.testing.expectEqualStrings(field(item, "name").string, package.name);
            try std.testing.expectEqualStrings(field(item, "version").string, package.version.raw);
            try expectOptional(field(item, "desc"), package.description);
            try expectOptional(field(item, "arch"), package.architecture);
            try expectOptional(field(item, "filename"), package.repository_filename);
            const size = field(item, "isize").integer;
            if (size < 0)
                try std.testing.expect(
                    package.installed_size == null and
                        package.metadata_issues.invalid_size,
                )
            else
                try std.testing.expectEqual(
                    @as(u64, @intCast(size)),
                    package.installed_size orelse 0,
                );
            try std.testing.expectEqual(field(item, "builddate").integer, package.build_date orelse 0);
            const files = field(item, "files").array.items;
            try std.testing.expectEqual(files.len, package.files.len);
            for (files, package.files) |file, actual|
                try std.testing.expectEqualStrings(
                    file.string,
                    actual.name,
                );
        }
        const group_ids = try owner.groupIds(io, db);
        const expected_groups = field(expected, "groups").array.items;
        try std.testing.expectEqual(expected_groups.len, group_ids.len);
        for (group_ids, expected_groups) |id, expected_group| {
            const group = (try owner.database(db)).groups.groups.items[@intFromEnum(id)];
            try std.testing.expectEqualStrings(field(expected_group, "name").string, group.name);
            try std.testing.expectEqual(
                field(expected_group, "packages").array.items.len,
                group.packages.items.len,
            );
        }
        for (packages) |item| {
            const target = (try owner.findPackage(db, field(item, "name").string)).?;
            const required = try owner.requiredBy(io, allocator, target);
            defer allocator.free(required);
            const optional = try owner.optionalFor(io, allocator, target);
            defer allocator.free(optional);
            const required_names = field(item, "requiredby").array.items;
            const optional_names = field(item, "optionalfor").array.items;
            try std.testing.expectEqual(required_names.len, required.len);
            try std.testing.expectEqual(optional_names.len, optional.len);
            for (required, required_names) |ref, name|
                try std.testing.expectEqualStrings(
                    name.string,
                    (try owner.package(ref)).name,
                );
            for (optional, optional_names) |ref, name|
                try std.testing.expectEqualStrings(
                    name.string,
                    (try owner.package(ref)).name,
                );
        }
        for (field(expected, "searches").array.items) |search| {
            var patterns: std.ArrayList([]const u8) = .empty;
            defer patterns.deinit(allocator);
            for (field(search, "patterns").array.items) |pattern|
                try patterns.append(allocator, pattern.string);
            if (!field(search, "success").bool) {
                try std.testing.expectError(
                    error.InvalidRegex,
                    owner.searchDatabase(
                        io,
                        allocator,
                        db,
                        patterns.items,
                    ),
                );
                continue;
            }
            const found = try owner.searchDatabase(io, allocator, db, patterns.items);
            defer allocator.free(found);
            const names = field(search, "names").array.items;
            try std.testing.expectEqual(names.len, found.len);
            for (names, found) |name, ref|
                try std.testing.expectEqualStrings(
                    name.string,
                    (try owner.package(ref)).name,
                );
        }
        try owner.setDatabaseUsage(
            db,
            .{
                .sync = false,
                .search = false,
                .install = false,
                .upgrade = false,
            },
        );
        const disabled = try owner.searchDatabase(io, allocator, db, &.{"["});
        defer allocator.free(disabled);
        try std.testing.expectEqual(0, disabled.len);
        try std.testing.expectEqual(
            field(expected, "disabled_exact_visible").bool,
            (try owner.queryPackage(io, db, "demo")) != null,
        );
    }
}

test "all reference compression filters and files extension build shared indexes" {
    for ([_]Archive.Compression{ .none, .gzip, .xz, .zstd, .bzip2 }) |compression| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.sync("test.files", &entries, compression, null);
        var config = fixture.config();
        config.database_extension = ".files";
        var owner = try rlpm.Owner.init(io, allocator, config, &.{.{ .database_name = "test" }});
        defer owner.deinit() catch unreachable;
        const db = owner.findDatabase("test").?;
        const ref = (try owner.queryPackage(io, db, "demo")).?;
        const package = try owner.package(ref);
        try std.testing.expect(package.findFile("etc/demo") != null);
        try std.testing.expect(package.findFile("/etc/demo") == null);
        try std.testing.expect(package.findFile("etc") == null);
        const group = (try owner.findGroup(io, db, "common")).?;
        try std.testing.expectEqual(2, group.packages.items.len);
        const groups = try owner.groupIds(io, db);
        for (groups, [_][]const u8{ "z-tools", "common", "editors" }) |id, name|
            try std.testing.expectEqualStrings(
                name,
                (try owner.database(db)).groups.groups.items[@intFromEnum(id)].name,
            );
    }
}

test "lazy local metadata streams provenance and missing-desc recovery" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.local("demo-1-1", desc);
    try fixture.local("missing-1-1", null);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "db/local/demo-1-1/files",
            .data = "%FILES%\netc/demo\n\n%BACKUP%\netc/demo\thash\n\n",
        },
    );
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/demo-1-1/install", .data = "shell" });
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "db/local/demo-1-1/changelog",
            .data = "history\n",
        },
    );
    const mtree = try Archive.gzip("#mtree\n./etc/demo type=file mode=644 size=42\n");
    defer allocator.free(mtree);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/demo-1-1/mtree", .data = mtree });
    var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{});
    var live = true;
    defer if (live) owner.deinit() catch unreachable;
    const db = owner.localDatabase().?;
    const ref = (try owner.findPackage(db, "demo")).?;
    const before = try owner.package(ref);
    try std.testing.expect(!before.description_loaded and !before.files_loaded);
    const package = try owner.packageMetadata(io, ref, .{ .files = true, .members = true });
    try std.testing.expectEqualStrings("removed-cachyos-repo", package.installed_database.?);
    try std.testing.expectEqualStrings("hash", package.backups[0].hash.?);
    try std.testing.expect(
        package.has_scriptlet and package.members.changelog == .present and
            package.members.mtree == .present,
    );
    var stream = (try package.openMember(allocator, .changelog)).?;
    defer stream.deinit();
    var tree = (try package.openMtree(allocator)).?;
    defer tree.deinit();
    try std.testing.expectEqualStrings("etc/demo", (try tree.next()).?.name);
    const missing = (try owner.findPackage(db, "missing")).?;
    try std.testing.expectError(error.FileNotFound, owner.packageMetadata(io, missing, .{}));
    try fixture.local("missing-1-1", "%DESC%\nrepaired\n\n");
    try std.testing.expectError(error.FileNotFound, owner.packageMetadata(io, missing, .{}));
    try owner.reloadDatabase(io, db);
    try std.testing.expectError(error.StalePackageReference, owner.package(missing));
    const repaired = (try owner.findPackage(db, "missing")).?;
    try std.testing.expectEqualStrings(
        "repaired",
        (try owner.packageMetadata(io, repaired, .{})).description.?,
    );
    try owner.deinit();
    live = false;
    const bytes = try stream.readAll(allocator, 100);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("history\n", bytes);
}

test "readonly absent local never writes and local ignores repository signature policy" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var config = fixture.config();
    config.local_database_mode = .read_only;
    var owner = try rlpm.Owner.init(io, allocator, config, &.{});
    defer owner.deinit() catch unreachable;
    try std.testing.expectEqual(.missing, (try owner.database(owner.localDatabase().?)).status.presence);
    try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.statFile(io, "db/local", .{}));
    try fixture.local("demo-1-1", desc);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
    const path = try std.fmt.allocPrint(allocator, "{s}/local", .{fixture.db});
    defer allocator.free(path);
    var database = try rlpm.Database.init(allocator, "local", path, .{ .database = .required });
    defer database.deinit();
    try database.loadDatabase(io, "/does-not-exist");
    try std.testing.expectEqual(1, database.packages.ordered.items.len);
}

test "usage-specific selection cross-repository groups and reverse dependencies" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.sync("first.db", &entries, .zstd, null);
    try fixture.sync("second.db", &entries, .gzip, null);
    var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{
        .{ .database_name = "first", .usage = .{ .install = false } },
        .{ .database_name = "second", .usage = .{
            .sync = false,
            .search = false,
            .upgrade = false,
        } },
    });
    defer owner.deinit() catch unreachable;
    const first = owner.findDatabase("first").?;
    const second = owner.findDatabase("second").?;
    try std.testing.expect((try owner.findCandidate(io, "demo", .install)).?.database.eql(second));
    try std.testing.expect((try owner.findCandidate(io, "demo", .upgrade)).?.database.eql(first));
    const refresh = try owner.repositoriesFor(allocator, .sync);
    defer allocator.free(refresh);
    try std.testing.expectEqual(1, refresh.len);
    try std.testing.expect(refresh[0].eql(first));
    const found = try owner.search(io, allocator, &.{"text"});
    defer allocator.free(found);
    try expectNames(&owner, found, &.{ "demo", "zeta" });
    const group = try owner.groupPackages(io, allocator, "common");
    defer allocator.free(group);
    try expectNames(&owner, group, &.{ "demo", "zeta" });
    try std.testing.expect(group[0].database.eql(first));
    try std.testing.expect((try owner.findGroup(io, second, "common")) != null);
    const demo = (try owner.findPackage(first, "demo")).?;
    const required = try owner.requiredBy(io, allocator, demo);
    defer allocator.free(required);
    const optional = try owner.optionalFor(io, allocator, demo);
    defer allocator.free(optional);
    try expectNames(&owner, required, &.{"zeta"});
    try expectNames(&owner, optional, &.{"zeta"});
    try owner.setDatabaseUsage(first, .{
        .search = false,
        .install = false,
        .upgrade = false,
    });
    const required_hidden = try owner.requiredBy(io, allocator, demo);
    defer allocator.free(required_hidden);
    try expectNames(&owner, required_hidden, &.{"zeta"});
}

test "failed reload retains generation while external format replacement invalidates references" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.sync("test.db", &entries, .zstd, null);
    var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{.{ .database_name = "test" }});
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("test").?;
    const ref = (try owner.queryPackage(io, db, "demo")).?;
    _ = try owner.findGroup(io, db, "common");
    try fixture.sync("test.db", &entries, .none, 520);
    try std.testing.expectError(error.ArchiveFailed, owner.reloadDatabase(io, db));
    try std.testing.expectEqualStrings("demo", (try owner.package(ref)).name);
    try std.testing.expect((try owner.database(db)).status.group_cache_loaded);
    try std.testing.expectEqual(error.ArchiveFailed, (try owner.database(db)).last_load_error.?);
    const reference = try std.json.parseFromSlice(
        Value,
        allocator,
        @embedFile("fixtures/database-reference.json"),
        .{},
    );
    defer reference.deinit();
    for (field(reference.value, "sync").array.items) |case| {
        if (!std.mem.eql(u8, field(case, "name").string, "sqlite")) continue;
        const bytes = try sqlImage(field(case, "columns").array.items, field(case, "rows").array.items);
        defer allocator.free(bytes);
        try fixture.sync("test.db", &.{.{ .path = "pacman.db", .contents = bytes }}, .zstd, null);
    }
    try owner.reloadDatabase(io, db);
    try std.testing.expectEqual(.sqlite, (try owner.database(db)).backend.sync.format);
    try std.testing.expectError(error.StalePackageReference, owner.package(ref));
    const replacement = (try owner.findPackage(db, "demo")).?;
    const package = try owner.package(replacement);
    try std.testing.expectEqualStrings("x86_64_v3", package.architecture.?);
    try std.testing.expectEqualStrings("libdemo.so", package.depends[1].name);
    try std.testing.expectEqualStrings("3-64", package.depends[1].constraint.equal);
    try std.testing.expectEqualStrings("compiler", package.make_depends[0].name);
    try std.testing.expectEqualStrings("tester", package.check_depends[0].name);
    try std.testing.expectEqualStrings("plain", package.provides[1].name);
    try std.testing.expect(package.availableValidation().pgp and package.availableValidation().sha256);
    try std.testing.expect(package.validation.none);
    try fixture.sync("test.db", &entries, .xz, null);
    try owner.reloadDatabase(io, db);
    try std.testing.expectEqual(.tar, (try owner.database(db)).backend.sync.format);
    try std.testing.expectError(error.StalePackageReference, owner.package(replacement));
    try owner.invalidateDatabase(db);
    try fixture.temporary.dir.deleteFile(io, "db/sync/test.db");
    try std.testing.expectError(error.FileNotFound, owner.ensureDatabase(io, db));
    try std.testing.expectEqual(.missing, (try owner.database(db)).status.presence);
    try fixture.sync("test.db", &entries, .gzip, null);
    try owner.ensureDatabase(io, db);
    try std.testing.expectEqual(2, (try owner.packageIds(db)).len);
}

fn allocationLifecycle(failing: std.mem.Allocator, root: []const u8, path: []const u8) !void {
    var owner = try rlpm.Owner.init(
        io,
        failing,
        .{ .root = root, .database_path = path },
        &.{.{ .database_name = "test" }},
    );
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("test").?;
    const ref = (try owner.queryPackage(io, db, "demo")).?;
    _ = try owner.findGroup(io, db, "common");
    const found = try owner.search(io, failing, &.{ "text", "common" });
    defer failing.free(found);
    const required = try owner.requiredBy(io, failing, ref);
    defer failing.free(required);
    try owner.reloadDatabase(io, db);
    const local = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    const package = try owner.packageMetadata(io, local, .{ .files = true, .members = true });
    var stream = (try package.openMember(failing, .changelog)).?;
    defer stream.deinit();
    const content = try stream.readAll(failing, 100);
    defer failing.free(content);
    try owner.setServers(db, .servers, &.{ "https://first.invalid//", "https://first.invalid//" });
    try owner.addServer(db, .cache_servers, "https://cache.invalid/");
    _ = try owner.removeServer(db, .servers, "https://first.invalid//");
    try owner.addListValue(io, .ignore_packages, "ignore-me");
}
test "cache metadata regex and reload allocations clean up at every injected failure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.sync("test.db", &entries, .zstd, null);
    try fixture.local("demo-1-1", desc);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "db/local/demo-1-1/files",
            .data = "%FILES%\netc/demo\n\n",
        },
    );
    try fixture.temporary.dir.writeFile(
        io,
        .{ .sub_path = "db/local/demo-1-1/changelog", .data = "history" },
    );
    try std.testing.checkAllAllocationFailures(
        allocator,
        allocationLifecycle,
        .{ fixture.root, fixture.db },
    );
    const reference = try std.json.parseFromSlice(
        Value,
        allocator,
        @embedFile("fixtures/database-reference.json"),
        .{},
    );
    defer reference.deinit();
    for (field(reference.value, "sync").array.items) |case| {
        if (!std.mem.eql(u8, field(case, "name").string, "sqlite")) continue;
        const bytes = try sqlImage(field(case, "columns").array.items, field(case, "rows").array.items);
        defer allocator.free(bytes);
        try fixture.sync("test.db", &.{.{ .path = "pacman.db", .contents = bytes }}, .zstd, null);
        try std.testing.checkAllAllocationFailures(
            allocator,
            allocationLifecycle,
            .{ fixture.root, fixture.db },
        );
    }
}

test "allocation failures preserve usable cache and metadata retry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.sync("test.db", &entries, .zstd, null);
    try fixture.local("demo-1-1", desc);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var owner = try rlpm.Owner.init(
        io,
        failing.allocator(),
        fixture.config(),
        &.{.{ .database_name = "test" }},
    );
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("test").?;
    const ref = (try owner.queryPackage(io, db, "demo")).?;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.reloadDatabase(io, db));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqualStrings("demo", (try owner.package(ref)).name);
    try std.testing.expect((try owner.database(db)).status.isUsable());
    const local = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.packageMetadata(io, local, .{}));
    try std.testing.expect(!(try owner.package(local)).description_loaded);
    try std.testing.expect((try owner.package(local)).metadata_error == null);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqualStrings(
        "Text utility",
        (try owner.packageMetadata(io, local, .{})).description.?,
    );
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.findGroup(io, db, "common"));
    try std.testing.expect(!(try owner.database(db)).status.group_cache_loaded);
    try std.testing.expectEqual(0, (try owner.database(db)).groups.by_name.count());
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(2, (try owner.findGroup(io, db, "common")).?.packages.items.len);
}

test "unrelated options and ordered server edits retain cache generations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.sync("test.db", &entries, .zstd, null);
    var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{.{ .database_name = "test" }});
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("test").?;
    const ref = (try owner.queryPackage(io, db, "demo")).?;
    _ = try owner.findGroup(io, db, "common");
    try owner.addListValue(io, .ignore_packages, "editor");
    try std.testing.expectEqualStrings("demo", (try owner.package(ref)).name);
    try std.testing.expect((try owner.database(db)).status.group_cache_loaded);
    try owner.setServers(db, .servers, &.{ "https://first.invalid//", "https://first.invalid//" });
    try owner.addServer(db, .servers, "https://second.invalid/");
    try owner.setServers(db, .cache_servers, &.{"https://cache.invalid/"});
    try owner.addServer(db, .cache_servers, "https://cache2.invalid/");
    try std.testing.expect(try owner.removeServer(db, .servers, "https://first.invalid//"));
    try std.testing.expect(try owner.removeServer(db, .cache_servers, "https://cache.invalid/"));
    try std.testing.expect(!try owner.removeServer(db, .servers, "absent"));
    try std.testing.expectError(error.InvalidOption, owner.setServers(db, .servers, &.{""}));
    const view = try owner.database(db);
    try std.testing.expectEqual(2, view.servers.items.len);
    try std.testing.expectEqualStrings("https://first.invalid/", view.servers.items[0]);
    try std.testing.expectEqualStrings("https://second.invalid", view.servers.items[1]);
    try std.testing.expectEqualStrings("https://cache2.invalid", view.cache_servers.items[0]);
    try std.testing.expectEqualStrings("demo", (try owner.package(ref)).name);
    var config = owner.options();
    config.database_extension = ".files";
    try owner.setOptions(io, config);
    try std.testing.expectError(error.StalePackageReference, owner.package(ref));
    try std.testing.expect(!(try owner.database(db)).status.group_cache_loaded);
}

test "unsafe archive paths links and malformed SQLite cannot publish a cache" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{.{ .database_name = "test" }});
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("test").?;
    for ([_]Archive.Entry{
        .{ .path = "../escape-1-1/desc", .contents = desc },
        .{ .path = "/absolute-1-1/desc", .contents = desc },
        .{ .path = "pacman.db", .contents = "not sqlite" },
        .{
            .path = "pacman.db",
            .kind = .symlink,
            .target = "/etc/passwd",
        },
        .{
            .path = "demo-1-1/desc",
            .kind = .hardlink,
            .target = "/etc/passwd",
        },
        .{ .path = "demo-1-1/desc", .contents = "%DESC%\nbad\x00bytes\n\n" },
    }) |bad| {
        try fixture.sync("test.db", &.{ entries[0], bad }, .zstd, null);
        if (owner.reloadDatabase(io, db)) |_|
            return error.ExpectedCorruptDatabase
        else |err|
            try std.testing.expect(err != error.OutOfMemory);
        try std.testing.expect(!(try owner.database(db)).status.package_cache_loaded);
        try std.testing.expectEqual(0, (try owner.database(db)).packages.by_name.count());
    }
    try std.testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.statFile(io, "root/escape-1-1", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.statFile(io, "root/pacman.db", .{}),
    );
}

test "reverse relations use only the installed universe for local and archive targets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.sync("test.db", &entries, .zstd, null);
    try fixture.local("demo-1-1", desc);
    try fixture.local("consumer-1-1", "%DEPENDS%\nvirtual>=3\n\n%OPTDEPENDS%\nplain: docs\n\n");
    try fixture.local("wrong-version-1-1", "%DEPENDS%\nvirtual>3\nplain=1\n\n");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
    var owner = try rlpm.Owner.init(io, allocator, fixture.config(), &.{.{ .database_name = "test" }});
    defer owner.deinit() catch unreachable;
    const target = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    const required = try owner.requiredBy(io, allocator, target);
    defer allocator.free(required);
    const optional = try owner.optionalFor(io, allocator, target);
    defer allocator.free(optional);
    try expectNames(&owner, required, &.{"consumer"});
    try expectNames(&owner, optional, &.{"consumer"});
    try std.testing.expect(!(try owner.database(owner.findDatabase("test").?)).status.package_cache_loaded);
    var archive = try Archive.init(
        &.{
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = archive\npkgver = 1-1\nprovides = virtual=3\n",
            },
        },
        .zstd,
    );
    defer archive.deinit();
    var package = try rlpm.Package.loadArchive(allocator, archive.path, .{});
    defer package.deinit();
    const archive_required = try owner.reverseDependencies(io, allocator, &package, false);
    defer allocator.free(archive_required);
    try expectNames(&owner, archive_required, &.{"consumer"});
}
