const std = @import("std");
const builtin = @import("builtin");
const manager = @import("manager.zig");
const bindings = @import("bindings.zig");
const events = @import("events.zig");
const operations = @import("operation_context");

const Manager = manager.Manager;
const libalpm = bindings.libalpm;
const rawLibalpm = libalpm.alpm;
const testing = std.testing;

const ErrorCapture = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    fn text(self: *const ErrorCapture) []const u8 {
        return self.buf[0..self.len];
    }
};

fn captureError(data: ?*anyopaque, args: events.ErrorArgs) void {
    const cap: *ErrorCapture = @ptrCast(@alignCast(data));
    const n = @min(args.message.len, cap.buf.len);
    @memcpy(cap.buf[0..n], args.message[0..n]);
    cap.len = n;
}

const InfoCapture = struct {
    args: ?events.InformationalArgs = null,
};

fn captureInfo(data: ?*anyopaque, args: events.InformationalArgs) void {
    const cap: *InfoCapture = @ptrCast(@alignCast(data));
    if (args.event_type == .failed_add_local_package) cap.args = args;
}

// ---------------------------------------------------------------------------
// init + sync (integration)
//
// These exercise the full path: parse a config, initialize libalpm, register a
// sync database, and download it over the network. Everything is confined to a
// unique temporary directory whose `DBPath` is redirected away from the host's
// real /var/lib/pacman, and the workspace is deleted once each test finishes.
// ---------------------------------------------------------------------------

// A throwaway pacman configuration written to disk under a unique temp root.
const SyncTestWorkspace = struct {
    io: std.Io,
    root: []const u8,
    config_path: []const u8,
    db_path: []const u8,

    fn create(allocator: std.mem.Allocator, io: std.Io) !SyncTestWorkspace {
        const anchor: u8 = 0;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
        const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-test-{x}", .{prng.random().int(u32)});
        errdefer allocator.free(root);

        const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
        errdefer allocator.free(db_path);

        const config_path = try std.fmt.allocPrint(allocator, "{s}/pacman.conf", .{root});
        errdefer allocator.free(config_path);

        // The pointer-seeded test name can repeat across separate test
        // processes, particularly after an interrupted run left files behind.
        std.Io.Dir.cwd().deleteTree(io, root) catch {};

        // Create the root and database directories up front.
        try std.Io.Dir.cwd().createDirPath(io, db_path);

        // A minimal config: DBPath points into our temp dir, and a single [core]
        // repository is aimed at a real Arch mirror. Signature checking is
        // disabled so no keyring/GPG setup is required to fetch the database.
        const config = try std.fmt.allocPrint(
            allocator,
            "[options]\n" ++
                "Architecture = auto\n" ++
                "SigLevel = Never\n" ++
                "DBPath = {s}\n" ++
                "\n" ++
                "[seafoam-labs]\n" ++
                "Server =  https://repo.seafoam-labs.org/x86_64\n",
            //"Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch\n",
            .{db_path},
        );
        defer allocator.free(config);

        var file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, config);

        return .{
            .io = io,
            .root = root,
            .config_path = config_path,
            .db_path = db_path,
        };
    }

    fn addLocalPackage(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
    ) !void {
        const package_dir = try std.fmt.allocPrint(
            allocator,
            "{s}/local/{s}-{s}",
            .{ self.db_path, name, version },
        );
        defer allocator.free(package_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, package_dir);

        const version_path = try std.fmt.allocPrint(allocator, "{s}/local/ALPM_DB_VERSION", .{self.db_path});
        defer allocator.free(version_path);
        var version_file = try std.Io.Dir.cwd().createFile(self.io, version_path, .{});
        defer version_file.close(self.io);
        try version_file.writeStreamingAll(self.io, "9\n");

        const desc_path = try std.fmt.allocPrint(allocator, "{s}/desc", .{package_dir});
        defer allocator.free(desc_path);
        const desc = try std.fmt.allocPrint(
            allocator,
            "%NAME%\n{s}\n\n" ++
                "%VERSION%\n{s}\n\n" ++
                "%DESC%\nTemporary package used by remove_packages tests\n\n" ++
                "%ARCH%\nany\n\n" ++
                "%REASON%\n0\n\n" ++
                "%VALIDATION%\nnone\n\n",
            .{ name, version },
        );
        defer allocator.free(desc);

        var desc_file = try std.Io.Dir.cwd().createFile(self.io, desc_path, .{});
        defer desc_file.close(self.io);
        try desc_file.writeStreamingAll(self.io, desc);

        const files_path = try std.fmt.allocPrint(allocator, "{s}/files", .{package_dir});
        defer allocator.free(files_path);
        var files = try std.Io.Dir.cwd().createFile(self.io, files_path, .{});
        defer files.close(self.io);
        try files.writeStreamingAll(self.io, "%FILES%\n\n");
    }

    fn createPackageArchive(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
    ) ![]u8 {
        const package_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}-{s}-any.pkg.tar",
            .{ self.root, name, version },
        );
        errdefer allocator.free(package_path);

        const pkginfo = try std.fmt.allocPrint(
            allocator,
            "pkgname = {s}\n" ++
                "pkgbase = {s}\n" ++
                "xdata = pkgtype=pkg\n" ++
                "pkgver = {s}\n" ++
                "pkgdesc = Temporary package used by install_local_packages tests\n" ++
                "url = https://example.invalid/{s}\n" ++
                "builddate = 0\n" ++
                "packager = Shelly test suite\n" ++
                "size = 0\n" ++
                "arch = any\n" ++
                "license = MIT\n",
            .{ name, name, version, name },
        );
        defer allocator.free(pkginfo);

        var file = try std.Io.Dir.cwd().createFile(self.io, package_path, .{});
        defer file.close(self.io);
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buffer);
        var archive_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
        try archive_writer.writeFileBytes(".PKGINFO", pkginfo, .{ .mode = 0o644 });
        try archive_writer.finishPedantically();
        try file_writer.interface.flush();

        return package_path;
    }

    fn createSyncDatabase(self: *const SyncTestWorkspace, allocator: std.mem.Allocator) !void {
        const sync_dir = try std.fmt.allocPrint(allocator, "{s}/sync", .{self.db_path});
        defer allocator.free(sync_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, sync_dir);

        const database_path = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{sync_dir});
        defer allocator.free(database_path);

        const provider_desc =
            "%FILENAME%\nremote-provider-2.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nremote-provider\n\n" ++
            "%BASE%\nremote-provider\n\n" ++
            "%VERSION%\n2.0-1\n\n" ++
            "%DESC%\nProvides a virtual dependency for Manager query tests\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n" ++
            "%PROVIDES%\nvirtual-feature=2\n\n";

        var file = try std.Io.Dir.cwd().createFile(self.io, database_path, .{});
        defer file.close(self.io);
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buffer);
        var archive_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
        try archive_writer.writeFileBytes("remote-provider-2.0-1/desc", provider_desc, .{ .mode = 0o644 });
        try archive_writer.finishPedantically();
        try file_writer.interface.flush();
    }

    // Removes the entire temp tree (config + downloaded databases) and frees the
    // owned path strings. Safe to call regardless of how far `create` got.
    fn cleanup(self: *SyncTestWorkspace, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        allocator.free(self.config_path);
        allocator.free(self.db_path);
        allocator.free(self.root);
    }
};

test "Manager.init registers the configured sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    try testing.expect(mgr.is_initialized);
    try testing.expect(mgr.handle != null);
    // applyConfig must have registered the [core] repository as a sync db.
    try testing.expect(mgr.sync_dbs.items.len >= 1);
}

test "Manager.sync downloads the configured database into DBPath/sync" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // Force the download so the result never depends on a pre-existing cache.
    try mgr.sync(true);

    // sync creates "<DBPath>/sync" and download_database stores each database
    // there under its bare repository name (no extension).
    const sync_dir = try std.fmt.allocPrint(allocator, "{s}/sync", .{workspace.db_path});
    defer allocator.free(sync_dir);
    _ = try std.Io.Dir.cwd().statFile(io, sync_dir, .{});

    const core_db = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{sync_dir});
    defer allocator.free(core_db);
    const stat = try std.Io.Dir.cwd().statFile(io, core_db, .{});
    try testing.expect(stat.size > 0);
}

// ---------------------------------------------------------------------------
// get_single_installed_package
// ---------------------------------------------------------------------------

test "get_single_installed_package returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_single_installed_package("anything");
    try testing.expectError(error.NoHandle, result);
}

test "get_single_installed_package returns null for a non-existent package" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // A fresh temporary database has no installed packages.
    const result = try mgr.get_single_installed_package("nonexistent-package");
    try testing.expect(result == null);
}

test "get_single_installed_package returns a package when it exists" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Use the real system database to find an actually installed package.
    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";

    // Skip gracefully if the system database is unavailable.
    const stat = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch {
        return; // no system database — skip
    };
    _ = stat;

    const mgr = Manager.init(allocator, testing.environ, sys_config, false, sys_db) catch {
        return; // config parse or init failure — skip
    };
    defer mgr.deinit();

    // `pacman` is installed on virtually every Arch-based system.
    const result = try mgr.get_single_installed_package("pacman");
    const pkg = result orelse return; // skip if pacman is somehow absent

    const name = pkg.name() orelse return error.TestFailed;
    try testing.expectEqualStrings("pacman", name);
}

// ---------------------------------------------------------------------------
// update_package_reason
// ---------------------------------------------------------------------------

test "update_package_reason returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;

    try testing.expectError(
        error.NoHandle,
        mgr.update_package_reason("shelly-test", .Dependency),
    );
}

test "update_package_reason changes an installed package reason" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-reason-test", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const initial = (try mgr.get_single_installed_package("shelly-reason-test")) orelse return error.TestFailed;
    try testing.expectEqual(libalpm.PackageReason.Explicit, initial.install_reason());

    try mgr.update_package_reason("shelly-reason-test", .Dependency);
    const dependency = (try mgr.get_single_installed_package("shelly-reason-test")) orelse return error.TestFailed;
    try testing.expectEqual(libalpm.PackageReason.Dependency, dependency.install_reason());

    try mgr.update_package_reason("shelly-reason-test", .Explicit);
    const explicit = (try mgr.get_single_installed_package("shelly-reason-test")) orelse return error.TestFailed;
    try testing.expectEqual(libalpm.PackageReason.Explicit, explicit.install_reason());
}

// ---------------------------------------------------------------------------
// get_installed_packages
// ---------------------------------------------------------------------------

test "get_installed_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_installed_packages();
    try testing.expectError(error.NoHandle, result);
}

test "get_installed_packages returns an empty list when no packages are installed" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    const packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    // A fresh temporary database has no installed packages.
    try testing.expectEqual(@as(usize, 0), packages.len);
}

test "ALPM queries honor shared cancellation" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    var context = operations.OperationContext.init(allocator, io);
    defer context.deinit();
    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();
    mgr.setOperationContext(&context);

    context.cancel();
    try testing.expectError(error.Cancelled, mgr.get_installed_packages());
}

test "get_installed_packages lists packages from the system database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Use the real system database, skipping gracefully when it is unavailable.
    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";
    _ = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch return;

    const mgr = Manager.init(allocator, testing.environ, sys_config, false, sys_db) catch return;
    defer mgr.deinit();

    const packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    // A real system always has packages installed, each exposing a name.
    try testing.expect(packages.len > 0);
    for (packages) |package| {
        _ = package.name() orelse return error.TestFailed;
    }

    // `pacman` is installed on every Arch-based system.
    var found_pacman = false;
    for (packages) |package| {
        const name = package.name() orelse continue;
        if (std.mem.eql(u8, name, "pacman")) {
            found_pacman = true;
            break;
        }
    }
    try testing.expect(found_pacman);
}

test "get_single_installed_package matches an entry from get_installed_packages" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";
    _ = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch return;

    const mgr = Manager.init(allocator, testing.environ, sys_config, false, sys_db) catch return;
    defer mgr.deinit();

    const packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);
    if (packages.len == 0) return;

    // Package names are null-terminated slices, so they can be looked up directly.
    const first_name = packages[0].name() orelse return error.TestFailed;
    const single = try mgr.get_single_installed_package(first_name);
    const pkg = single orelse return error.TestFailed;
    const single_name = pkg.name() orelse return error.TestFailed;
    try testing.expectEqualStrings(first_name, single_name);
}

// ---------------------------------------------------------------------------
// get_foreign_packages
// ---------------------------------------------------------------------------

test "get_foreign_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_foreign_packages();
    try testing.expectError(error.NoHandle, result);
}

test "get_foreign_packages returns an empty list when no packages are installed" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    const foreign = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, foreign);

    // With no installed packages there is nothing that could be foreign.
    try testing.expectEqual(@as(usize, 0), foreign.len);
}

test "get_foreign_packages excludes packages provided by a sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sys_config = "/etc/pacman.conf";
    const sys_db = "/var/lib/pacman";
    _ = std.Io.Dir.cwd().statFile(io, sys_db, .{}) catch return;

    const mgr = Manager.init(allocator, testing.environ, sys_config, false, sys_db) catch return;
    defer mgr.deinit();

    const installed = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, installed);

    const foreign = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, foreign);

    // Foreign packages are always a subset of the installed packages.
    try testing.expect(foreign.len <= installed.len);

    // Every foreign package is nonetheless installed, so it resolves locally.
    for (foreign) |package| {
        const name = package.name() orelse return error.TestFailed;
        const local = try mgr.get_single_installed_package(name);
        try testing.expect(local != null);
    }

    // If some packages were matched to a sync database, the sync caches are
    // loaded and repository packages must be excluded. `pacman` ships from the
    // official [core] repository, so it must never be reported as foreign.
    if (foreign.len < installed.len) {
        for (foreign) |package| {
            const name = package.name() orelse continue;
            try testing.expect(!std.mem.eql(u8, name, "pacman"));
        }
    }
}

// ---------------------------------------------------------------------------
// Local-database symlink (non-root update checking)
//
// When a temp root is supplied, Manager.init symlinks "{tempRoot}/local" to the
// real "{DBPath}/local" so libalpm can see the actually installed packages
// while every write (sync databases, etc.) stays inside the throwaway temp
// root. These tests drive that path against the real system database.
// ---------------------------------------------------------------------------

// A throwaway temp root whose config points DBPath at the *real* system
// database, so Manager.init links the real `local` directory into the temp root.
const LocalDbTestWorkspace = struct {
    io: std.Io,
    root: []const u8,
    config_path: []const u8,
    real_db_path: []const u8,

    // The real system database whose `local` directory holds installed packages.
    const system_db_path = "/var/lib/pacman";

    // Returns null (skip) when the real local database is unavailable, e.g. on
    // non-Arch hosts or CI without a populated /var/lib/pacman/local.
    fn create(allocator: std.mem.Allocator, io: std.Io) !?LocalDbTestWorkspace {
        const real_local = try std.fmt.allocPrint(allocator, "{s}/local", .{system_db_path});
        defer allocator.free(real_local);
        _ = std.Io.Dir.cwd().statFile(io, real_local, .{}) catch return null;

        const anchor: u8 = 0;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
        const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-local-test-{x}", .{prng.random().int(u32)});
        errdefer allocator.free(root);

        const config_path = try std.fmt.allocPrint(allocator, "{s}/pacman.conf", .{root});
        errdefer allocator.free(config_path);

        // The temp root must exist so init can plant the "local" symlink inside it.
        try std.Io.Dir.cwd().createDirPath(io, root);

        // DBPath points at the *real* database; init captures "{DBPath}/local",
        // repoints DBPath to the temp root (passed as temp_root_path), and links
        // "{tempRoot}/local" -> "{real}/local". No repositories are configured,
        // so no sync database is registered.
        const config = try std.fmt.allocPrint(
            allocator,
            "[options]\n" ++
                "Architecture = auto\n" ++
                "SigLevel = Never\n" ++
                "DBPath = {s}\n",
            .{system_db_path},
        );
        defer allocator.free(config);

        var file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, config);

        return .{
            .io = io,
            .root = root,
            .config_path = config_path,
            .real_db_path = system_db_path,
        };
    }

    // deleteTree unlinks the "local" symlink without touching its target.
    fn cleanup(self: *LocalDbTestWorkspace, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        allocator.free(self.config_path);
        allocator.free(self.root);
    }
};

test "Manager.init symlinks the real local database into the temp root" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    const link_path = try std.fmt.allocPrint(allocator, "{s}/local", .{workspace.root});
    defer allocator.free(link_path);

    // The temp-root entry must be a symlink...
    const link_stat = try std.Io.Dir.cwd().statFile(io, link_path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);

    // ...pointing at the real "{DBPath}/local" directory...
    const expected_target = try std.fmt.allocPrint(allocator, "{s}/local", .{workspace.real_db_path});
    defer allocator.free(expected_target);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, link_path, &buf);
    try testing.expectEqualStrings(expected_target, buf[0..n]);

    // ...and following the link must resolve to the real database directory.
    const target_stat = try std.Io.Dir.cwd().statFile(io, link_path, .{ .follow_symlinks = true });
    try testing.expectEqual(std.Io.File.Kind.directory, target_stat.kind);
}

test "get_installed_packages reads real packages through the local symlink" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    const packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    // The real system database always has packages installed.
    try testing.expect(packages.len > 0);

    // `pacman` is installed on every Arch-based system and must be visible
    // through the symlinked local database.
    var found_pacman = false;
    for (packages) |package| {
        const name = package.name() orelse continue;
        if (std.mem.eql(u8, name, "pacman")) {
            found_pacman = true;
            break;
        }
    }
    try testing.expect(found_pacman);
}

test "get_single_installed_package resolves a real package through the local symlink" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    // An installed package resolves through the symlinked local database...
    const pkg = (try mgr.get_single_installed_package("pacman")) orelse return error.TestFailed;
    try testing.expectEqualStrings("pacman", pkg.name() orelse return error.TestFailed);

    // ...while a package that is not installed does not.
    try testing.expect((try mgr.get_single_installed_package("shelly-definitely-not-installed")) == null);
}

test "get_foreign_packages treats installed packages as foreign without a sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = (try LocalDbTestWorkspace.create(allocator, io)) orelse return;
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.root);
    defer mgr.deinit();

    const installed = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, installed);
    try testing.expect(installed.len > 0);

    const foreign = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, foreign);

    // The workspace configures no repositories, so no sync database is
    // registered and every installed package counts as foreign.
    try testing.expectEqual(installed.len, foreign.len);
}

fn containsPackage(packages: []const libalpm.OwnedPackage, name: []const u8) bool {
    for (packages) |package| {
        const pkg_name = package.name() orelse continue;
        if (std.mem.eql(u8, pkg_name, name)) return true;
    }
    return false;
}

// Mirrors the non-root `check-updates` flow in the C# CLI
// (CheckPackageUpdateNonRoot.GetSyncStandards): initialize against the real
// system configuration with `use_root = false` and a throwaway temp root
// (equivalent to `Initialize(useTempPath: true, tempPath: ...)`), then `sync()`
// the configured repositories. init symlinks the temp root's `local` database
// to the real one, so installed packages are visible while every downloaded
// sync database lands in the temp root. This exercises get_installed_packages
// and get_foreign_packages together against real repository data.
test "get_foreign_packages excludes repository packages after a non-root sync" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Skip gracefully when there is no real system database to link against.
    const sys_config = "/etc/pacman.conf";
    _ = std.Io.Dir.cwd().statFile(io, "/var/lib/pacman/local", .{}) catch return;

    // A unique temp root plays the role of the C# `tempPath` cache directory.
    const anchor: u8 = 0;
    var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
    const temp_root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-checkupdates-{x}", .{prng.random().int(u32)});
    defer allocator.free(temp_root);
    try std.Io.Dir.cwd().createDirPath(io, temp_root);
    defer std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};

    // Initialize(useTempPath: true, tempPath: temp_root) + Sync().
    const mgr = Manager.init(allocator, testing.environ, sys_config, false, temp_root) catch return;
    defer mgr.deinit();
    mgr.sync(true) catch return;

    const installed = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, installed);

    const foreign = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, foreign);

    // The linked local database always exposes the real installed packages.
    try testing.expect(installed.len > 0);
    try testing.expect(containsPackage(installed, "pacman"));

    // Skip the exclusion assertions unless the sync actually loaded repository
    // data (network available and databases downloaded). Without it every
    // installed package would trivially be "foreign".
    if (foreign.len == installed.len) return;

    // `pacman` is provided by the official [core] repository, so once its sync
    // database is loaded it must never be reported as a foreign package.
    try testing.expect(!containsPackage(foreign, "pacman"));
    try testing.expect(foreign.len < installed.len);
}

// ---------------------------------------------------------------------------
// get_available_packages
// ---------------------------------------------------------------------------

test "get_available_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_available_packages();
    try testing.expectError(error.NoHandle, result);
}

test "get_available_packages returns an empty list when no sync databases are populated" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // init registers the sync database but does not download it, so there are
    // no packages available until sync() is called.
    const packages = try mgr.get_available_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    try testing.expectEqual(@as(usize, 0), packages.len);
}

test "get_available_packages returns packages after a successful sync" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // Download the remote database so packages become available.
    try mgr.sync(true);

    const packages = try mgr.get_available_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    // A real repository always exposes packages, each with a readable name.
    try testing.expect(packages.len > 0);
    for (packages) |package| {
        _ = package.name() orelse return error.TestFailed;
    }
}

test "toggle_hidden_packages flips state and returns the new value" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    try testing.expectEqual(false, mgr.show_hidden_packages);
    try testing.expectEqual(true, mgr.toggle_hidden_packages());
    try testing.expectEqual(true, mgr.show_hidden_packages);
    try testing.expectEqual(false, mgr.toggle_hidden_packages());
    try testing.expectEqual(false, mgr.show_hidden_packages);
}

// ---------------------------------------------------------------------------
// install_packages
// ---------------------------------------------------------------------------

test "install_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    var package_names = [_][:0]const u8{"anything"};
    try testing.expectError(
        error.NoHandle,
        mgr.install_packages(&package_names, .{}),
    );
}

test "install_packages rejects an empty package list" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var package_names = [_][:0]const u8{};
    try testing.expectError(
        error.PackageFetchFailed,
        mgr.install_packages(&package_names, .{}),
    );
}

test "install_packages rejects malformed repository-qualified targets" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    const malformed = [_][:0]const u8{ "/package", "repository/" };
    for (malformed) |target| {
        var package_names = [_][:0]const u8{target};
        try testing.expectError(
            error.PackageFetchFailed,
            mgr.install_packages(&package_names, .{}),
        );
    }
}

test "install_packages returns PackageFetchFailed when a target cannot be resolved" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var unqualified = [_][:0]const u8{"shelly-package-that-does-not-exist"};
    try testing.expectError(
        error.PackageFetchFailed,
        mgr.install_packages(&unqualified, .{}),
    );

    var qualified = [_][:0]const u8{"seafoam-labs/shelly-package-that-does-not-exist"};
    try testing.expectError(
        error.PackageFetchFailed,
        mgr.install_packages(&qualified, .{}),
    );
}

test "install_packages predownloads prepared repository packages before commit" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.createSyncDatabase(allocator);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/cache", .{workspace.root});
    defer allocator.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);

    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\n" ++
            "Architecture = auto\n" ++
            "SigLevel = Never\n" ++
            "DBPath = {s}\n" ++
            "CacheDir = {s}\n" ++
            "\n" ++
            "[seafoam-labs]\n" ++
            "Server = file://{s}/mirror\n",
        .{ workspace.db_path, cache_path, workspace.root },
    );
    defer allocator.free(config);
    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const CancelDownload = struct {
        context: *operations.OperationContext,
        saw_download: bool = false,

        fn handle(data: ?*anyopaque, event: operations.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (event) {
                .started => |started| {
                    if (started.envelope.backend != .download) return;
                    self.saw_download = true;
                    self.context.cancel();
                },
                else => {},
            }
        }
    };
    var context = operations.OperationContext.init(allocator, io);
    defer context.deinit();
    var cancel_download: CancelDownload = .{ .context = &context };
    _ = try context.subscribe(.{ .function = CancelDownload.handle, .data = &cancel_download });
    mgr.setOperationContext(&context);

    var package_names = [_][:0]const u8{"remote-provider"};
    try testing.expectError(
        error.UpdateFetchFailed,
        mgr.install_packages(&package_names, .{}),
    );
    try testing.expect(cancel_download.saw_download);
}

// ---------------------------------------------------------------------------
// install_local_packages
// ---------------------------------------------------------------------------

test "install_local_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;

    var paths = [_][]const u8{"anything.pkg.tar"};
    try testing.expectError(
        error.NoHandle,
        mgr.install_local_packages(&paths, .{}),
    );
}

test "install_local_packages rejects an empty path list" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    var paths = [_][]const u8{};
    try testing.expectError(
        error.NoPackageFound,
        mgr.install_local_packages(&paths, .{}),
    );
}

test "install_local_packages reports an unreadable package archive" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    var capture = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = captureError, .data = @ptrCast(&capture) });

    const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing.pkg.tar", .{workspace.root});
    defer allocator.free(missing_path);
    var paths = [_][]const u8{missing_path};

    try testing.expectError(
        error.PackageLoadFailed,
        mgr.install_local_packages(&paths, .{}),
    );
    try testing.expect(capture.len != 0);
}

test "install_local_packages installs multiple archives in a DB-only transaction" {
    const allocator = testing.allocator;

    // libalpm rejects package commit transactions for unprivileged processes,
    // even when DBONLY confines the mutation to a temporary database.
    if (builtin.os.tag != .linux or std.os.linux.geteuid() != 0) return;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const first_path = try workspace.createPackageArchive(allocator, "shelly-local-first", "1.0-1");
    defer allocator.free(first_path);
    const second_path = try workspace.createPackageArchive(allocator, "shelly-local-second", "2.0-1");
    defer allocator.free(second_path);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();
    try testing.expectEqual(@as(c_int, 0), libalpm.alpm.alpm_option_set_hookdirs(mgr.handle, null));

    var paths = [_][]const u8{ first_path, second_path };
    try mgr.install_local_packages(&paths, .{ .dbonly = true });

    const first = (try mgr.get_single_installed_package("shelly-local-first")) orelse return error.TestFailed;
    const second = (try mgr.get_single_installed_package("shelly-local-second")) orelse return error.TestFailed;
    try testing.expectEqualStrings("1.0-1", first.version() orelse return error.TestFailed);
    try testing.expectEqualStrings("2.0-1", second.version() orelse return error.TestFailed);
}

test "install_local_packages skips a duplicate target and emits information" {
    const allocator = testing.allocator;

    if (builtin.os.tag != .linux or std.os.linux.geteuid() != 0) return;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const package_path = try workspace.createPackageArchive(allocator, "shelly-local-duplicate", "1.0-1");
    defer allocator.free(package_path);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();
    try testing.expectEqual(@as(c_int, 0), libalpm.alpm.alpm_option_set_hookdirs(mgr.handle, null));

    var capture = InfoCapture{};
    _ = try mgr.dispatcher.addInformationalHandler(.{ .function = captureInfo, .data = @ptrCast(&capture) });

    var paths = [_][]const u8{ package_path, package_path };
    try mgr.install_local_packages(&paths, .{ .dbonly = true });

    const args = capture.args orelse return error.TestFailed;
    try testing.expectEqual(libalpm.EventType.failed_add_local_package, args.event_type);
    try testing.expectEqualStrings("Failed to add local package.", args.message);
    try testing.expect((try mgr.get_single_installed_package("shelly-local-duplicate")) != null);
}

// ---------------------------------------------------------------------------
// remove_packages
// ---------------------------------------------------------------------------

test "remove_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    var package_names = [_][:0]const u8{"anything"};
    try testing.expectError(
        error.NoHandle,
        mgr.remove_packages(&package_names, .{}, true),
    );
}

test "remove_packages rejects an empty package list" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var package_names = [_][:0]const u8{};
    try testing.expectError(
        error.NoPackageFound,
        mgr.remove_packages(&package_names, .{}, true),
    );
}

test "remove_packages returns NoPackageFound for an unknown target" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var capture = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = captureError, .data = @ptrCast(&capture) });

    var package_names = [_][:0]const u8{"shelly-package-that-does-not-exist"};
    try testing.expectError(
        error.NoPackageFound,
        mgr.remove_packages(&package_names, .{}, true),
    );
    try testing.expectEqualStrings("Failed to find package", capture.text());
}

test "remove_packages cancels removal of a held package without confirmation" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    var capture = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = captureError, .data = @ptrCast(&capture) });

    // "shelly" is included in the configuration's default HoldPkg entries.
    // With no question handler, askYesNo defaults to false.
    var package_names = [_][:0]const u8{"shelly"};
    try testing.expectError(
        error.PrepareFailed,
        mgr.remove_packages(&package_names, .{}, true),
    );
    try testing.expectEqualStrings("Held package removal cancelled.", capture.text());
}

test "remove_packages removes an installed package in a DB-only transaction when root" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-remove-test", "1.0-1");

    // libalpm rejects removal transactions for unprivileged processes even
    // when DBONLY confines the mutation to this temporary database.
    if (builtin.os.tag != .linux or std.os.linux.geteuid() != 0) return;

    // DBPath already points at the isolated workspace. Passing it again as the
    // non-root temp path would replace its local database with a symlink.
    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();
    try testing.expectEqual(@as(c_int, 0), libalpm.alpm.alpm_option_set_hookdirs(mgr.handle, null));

    try testing.expect((try mgr.get_single_installed_package("shelly-remove-test")) != null);

    var package_names = [_][:0]const u8{"shelly-remove-test"};
    try mgr.remove_packages(&package_names, .{ .dbonly = true }, true);
    try testing.expect((try mgr.get_single_installed_package("shelly-remove-test")) == null);
}

// ---------------------------------------------------------------------------
// get_updates_available
// ---------------------------------------------------------------------------

test "get_updates_available returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    const result = mgr.get_updates_available();
    try testing.expectError(error.NoHandle, result);
}

test "get_updates_available returns an empty list when no packages are installed" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, workspace.db_path);
    defer mgr.deinit();

    // A fresh temporary database has no installed packages, so there are no
    // updates available even after a sync.
    try mgr.sync(true);

    const updates = try mgr.get_updates_available();
    defer libalpm.OwnedPackageWithUpdate.deinitSlice(allocator, updates);

    try testing.expectEqual(@as(usize, 0), updates.len);
}

test "get_updates_available returns updates when installed packages have newer versions" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Skip gracefully when there is no real system database to link against.
    _ = std.Io.Dir.cwd().statFile(io, "/var/lib/pacman/local", .{}) catch return;

    // A unique temp root plays the role of the C# `tempPath` cache directory.
    const anchor: u8 = 0;
    var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
    const temp_root = try std.fmt.allocPrint(allocator, "/tmp/shelly-alpm-updates-{x}", .{prng.random().int(u32)});
    defer allocator.free(temp_root);
    try std.Io.Dir.cwd().createDirPath(io, temp_root);
    defer std.Io.Dir.cwd().deleteTree(io, temp_root) catch {};

    // Initialize against the real system configuration with a throwaway temp root.
    const mgr = Manager.init(allocator, testing.environ, "/etc/pacman.conf", false, temp_root) catch return;
    defer mgr.deinit();

    // Download the remote databases so alpm_sync_get_new_version can compare
    // installed packages against the repository versions.
    mgr.sync(true) catch return;

    const updates = try mgr.get_updates_available();
    defer libalpm.OwnedPackageWithUpdate.deinitSlice(allocator, updates);

    // Each entry must have both an old (installed) and a new (repository) package.
    for (updates) |update| {
        const old_name = update.old_package.name() orelse return error.TestFailed;
        const new_name = update.new_package.name() orelse return error.TestFailed;
        // The package names must match — we are comparing the same package.
        try testing.expectEqualStrings(old_name, new_name);
    }
}

// ---------------------------------------------------------------------------
// Priority 0 public API coverage
// ---------------------------------------------------------------------------

test "previously uncovered Manager APIs reject a null handle" {
    var mgr: Manager = undefined;
    mgr.handle = null;
    mgr.allocator = testing.allocator;

    try testing.expectError(error.SyncDbFailed, mgr.sync_for_update_check(false));
    try testing.expectError(error.NoHandle, mgr.sync_system_update(.{}));
    try testing.expectError(error.NoHandle, mgr.get_package_from_provides("virtual-feature"));
    try testing.expectError(error.NoHandle, mgr.is_dependency_satisfied_by_installed_packages("dependency"));
    try testing.expectError(error.NoHandle, mgr.find_remote_satisfier_for_dependency("dependency"));
    try testing.expectError(error.NoHandle, mgr.find_remote_satisfier_for_dependency_details("dependency"));
    try testing.expectError(error.NoHandle, mgr.get_configured_cache_directories());
    try testing.expectError(error.NoHandle, mgr.install_dependencies_only("package", false, .{}));

    var no_packages = [_][:0]const u8{};
    try testing.expectError(error.NoHandle, mgr.update_packages(&no_packages, .{}));

    try testing.expectError(error.NoHandle, mgr.purify(true, false, false));
    try testing.expect(!mgr.is_package_installed("package"));
    try testing.expectError(error.NoHandle, mgr.get_allowed_architecture());
}

test "dependency query APIs resolve exact, versioned, and virtual remote packages" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.createSyncDatabase(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try testing.expectEqualStrings(
        "remote-provider",
        try mgr.get_package_from_provides("remote-provider"),
    );
    try testing.expectEqualStrings(
        "remote-provider",
        try mgr.find_remote_satisfier_for_dependency("remote-provider>=2.0"),
    );
    try testing.expectEqualStrings(
        "remote-provider",
        try mgr.get_package_from_provides("virtual-feature>=2"),
    );
    try testing.expectEqualStrings(
        "remote-provider",
        try mgr.find_remote_satisfier_for_dependency("virtual-feature>=2"),
    );
    const direct_satisfier = try mgr.find_remote_satisfier_for_dependency_details("remote-provider>=2.0");
    try testing.expectEqualStrings("remote-provider", direct_satisfier.real_name);
    try testing.expect(!direct_satisfier.via_provides);

    const provided_satisfier = try mgr.find_remote_satisfier_for_dependency_details("virtual-feature>=2");
    try testing.expectEqualStrings("remote-provider", provided_satisfier.real_name);
    try testing.expect(provided_satisfier.via_provides);
    try testing.expectError(error.PkgNotFound, mgr.get_package_from_provides("missing-feature"));
    try testing.expectError(error.PkgNotFound, mgr.find_remote_satisfier_for_dependency("missing-feature"));
    try testing.expectError(error.PkgNotFound, mgr.find_remote_satisfier_for_dependency_details("missing-feature"));
}

test "installed dependency query distinguishes satisfied and missing dependencies" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-installed-dependency", "2.0-1");

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try testing.expect(try mgr.is_dependency_satisfied_by_installed_packages("shelly-installed-dependency"));
    try testing.expect(try mgr.is_dependency_satisfied_by_installed_packages("shelly-installed-dependency>=2.0"));
    try testing.expect(!try mgr.is_dependency_satisfied_by_installed_packages("shelly-missing-dependency"));
}

test "install_dependencies_only reports a package missing from local and sync databases" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try testing.expectError(
        error.NoPackageFound,
        mgr.install_dependencies_only("shelly-package-that-does-not-exist", false, .{}),
    );
}

test "purify with every mode disabled returns no targets" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const targets = try mgr.purify(true, false, false);
    defer allocator.free(targets);
    try testing.expectEqual(@as(usize, 0), targets.len);
}

test "is_package_installed reports installed and missing packages" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-installed-query", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try testing.expect(mgr.is_package_installed("shelly-installed-query"));
    try testing.expect(!mgr.is_package_installed("shelly-missing-query"));
}

test "Manager ignore APIs mutate and report normalized ignored packages" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try mgr.ignore_package(" first-package ");
    const additions = [_][]const u8{ "second-package", "first-package", " third-package " };
    try mgr.ignore_packages(&additions);

    var ignored = try mgr.get_ignored_packages();
    defer ignored.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), ignored.items.len);
    try testing.expectEqualStrings("first-package", ignored.items[0]);
    try testing.expectEqualStrings("second-package", ignored.items[1]);
    try testing.expectEqualStrings("third-package", ignored.items[2]);

    try mgr.unignore_package(" second-package ");
    const removals = [_][]const u8{ "first-package", "third-package", "not-ignored" };
    try mgr.unignore_packages(&removals);

    var after_remove = try mgr.get_ignored_packages();
    defer after_remove.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), after_remove.items.len);

    const rewritten = try std.Io.Dir.cwd().readFileAlloc(
        io,
        workspace.config_path,
        allocator,
        .unlimited,
    );
    defer allocator.free(rewritten);
    try testing.expect(std.mem.indexOf(u8, rewritten, "#IgnorePkg =") != null);
}

test "Manager hold APIs mutate HoldPkg while retaining shelly" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try mgr.hold_package(" linux ");
    var held = try mgr.get_held_packages();
    defer held.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), held.items.len);
    try testing.expectEqualStrings("linux", held.items[3]);

    const removals = [_][]const u8{ "pacman", "glibc", "linux", "shelly" };
    try mgr.unhold_packages(&removals);
    var remaining = try mgr.get_held_packages();
    defer remaining.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), remaining.items.len);
    try testing.expectEqualStrings("shelly", remaining.items[0]);

    const rewritten = try std.Io.Dir.cwd().readFileAlloc(
        io,
        workspace.config_path,
        allocator,
        .unlimited,
    );
    defer allocator.free(rewritten);
    try testing.expect(std.mem.indexOf(u8, rewritten, "HoldPkg = shelly") != null);
}

test "get_allowed_architecture returns the resolved host architecture and any" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const architectures = try mgr.get_allowed_architecture();
    defer {
        for (architectures) |architecture| allocator.free(architecture);
        allocator.free(architectures);
    }

    const expected_host = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "x86_64",
    };
    try testing.expectEqual(@as(usize, 2), architectures.len);
    try testing.expectEqualStrings(expected_host, architectures[0]);
    try testing.expectEqualStrings("any", architectures[1]);
}

// ---------------------------------------------------------------------------
// Priority 1 behavioral and error-path coverage
// ---------------------------------------------------------------------------

test "valid managers without sync databases report SyncDbFailed for sync update APIs" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\n" ++
            "Architecture = auto\n" ++
            "SigLevel = Never\n" ++
            "DBPath = {s}\n",
        .{workspace.db_path},
    );
    defer allocator.free(config);

    var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
    defer config_file.close(io);
    try config_file.writeStreamingAll(io, config);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try testing.expectError(error.SyncDbFailed, mgr.sync(false));
    try testing.expectError(error.SyncDbFailed, mgr.sync_system_update(.{ .dbonly = true }));

    var package_names = [_][:0]const u8{"not-installed"};
    try testing.expectError(
        error.SyncDbFailed,
        mgr.update_packages(&package_names, .{ .dbonly = true }),
    );
}

test "update_package_reason reports PackageFetchFailed for a missing package" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try testing.expectError(
        error.PackageFetchFailed,
        mgr.update_package_reason("shelly-missing-reason-package", .Dependency),
    );
}

test "install_dependencies_only succeeds when the target has no dependencies" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-no-dependencies", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try mgr.install_dependencies_only(
        "shelly-no-dependencies",
        true,
        .{ .dbonly = true },
    );
    try testing.expect(mgr.is_package_installed("shelly-no-dependencies"));
}

test "purify dry run identifies dependency packages that are no longer required" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-orphan", "1.0-1");
    try workspace.addLocalPackage(allocator, "shelly-explicit", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();
    try mgr.update_package_reason("shelly-orphan", .Dependency);

    const targets = try mgr.purify(true, true, false);
    defer {
        for (targets) |target| allocator.free(target);
        allocator.free(targets);
    }

    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqualStrings("shelly-orphan", targets[0]);
    try testing.expect(mgr.is_package_installed("shelly-orphan"));
    try testing.expect(mgr.is_package_installed("shelly-explicit"));
}

test "purify reports DirectoryReadFailed when the package cache cannot be opened" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const missing_cache = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/missing-cache",
        .{workspace.root},
        0,
    );
    defer allocator.free(missing_cache);
    mgr.config.cache_directory = missing_cache;

    try testing.expectError(
        error.DirectoryReadFailed,
        mgr.purify(true, false, true),
    );
}

// ---------------------------------------------------------------------------
// Priority 2 low-level configuration and filesystem coverage
// ---------------------------------------------------------------------------

test "Manager.init registers and deduplicates repository microarchitectures" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\n" ++
            "Architecture = auto\n" ++
            "SigLevel = Never\n" ++
            "DBPath = {s}\n" ++
            "\n" ++
            "[microarchitecture-test]\n" ++
            "Server = https://example.invalid/$archv4\n" ++
            "Server = https://backup.example.invalid/$archv4\n",
        .{workspace.db_path},
    );
    defer allocator.free(config);

    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const architectures = try mgr.get_allowed_architecture();
    defer {
        for (architectures) |architecture| allocator.free(architecture);
        allocator.free(architectures);
    }

    const host = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "x86_64",
    };
    const expected = [_][]const u8{
        host,
        "any",
        try std.fmt.allocPrint(allocator, "{s}_v4", .{host}),
        try std.fmt.allocPrint(allocator, "{s}_v3", .{host}),
        try std.fmt.allocPrint(allocator, "{s}_v2", .{host}),
    };
    defer {
        allocator.free(expected[2]);
        allocator.free(expected[3]);
        allocator.free(expected[4]);
    }

    try testing.expectEqual(expected.len, architectures.len);
    for (expected) |wanted| {
        var count: usize = 0;
        for (architectures) |actual| {
            if (std.mem.eql(u8, wanted, actual)) count += 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "purify corruption dry run reports only invalid package archives" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const cache_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/cache",
        .{workspace.root},
        0,
    );
    defer allocator.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);
    mgr.config.cache_directory = cache_path;

    const valid_source = try workspace.createPackageArchive(allocator, "valid-cache", "1.0-1");
    defer allocator.free(valid_source);
    const valid_path = try std.fmt.allocPrint(
        allocator,
        "{s}/valid-cache-1.0-1-any.pkg.tar",
        .{cache_path},
    );
    defer allocator.free(valid_path);
    try std.Io.Dir.rename(.cwd(), valid_source, .cwd(), valid_path, io);

    const archive_path = try std.fmt.allocPrint(
        allocator,
        "{s}/candidate.pkg.tar.zst",
        .{cache_path},
    );
    defer allocator.free(archive_path);
    const signature_path = try std.fmt.allocPrint(
        allocator,
        "{s}/candidate.pkg.tar.zst.sig",
        .{cache_path},
    );
    defer allocator.free(signature_path);
    const unrelated_path = try std.fmt.allocPrint(
        allocator,
        "{s}/notes.txt",
        .{cache_path},
    );
    defer allocator.free(unrelated_path);

    for ([_][]const u8{ archive_path, signature_path, unrelated_path }) |path| {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        file.close(io);
    }

    const targets = try mgr.purify(true, false, true);
    defer {
        for (targets) |target| allocator.free(target);
        allocator.free(targets);
    }

    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqualStrings("candidate.pkg.tar.zst", targets[0]);
    _ = try std.Io.Dir.cwd().statFile(io, valid_path, .{});
    _ = try std.Io.Dir.cwd().statFile(io, archive_path, .{});
}

// ---------------------------------------------------------------------------
// Priority 3 resilience and fault-injection coverage
// ---------------------------------------------------------------------------

test "Manager.init ignores malformed and sub-v2 microarchitecture suffixes" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\n" ++
            "Architecture = auto\n" ++
            "SigLevel = Never\n" ++
            "DBPath = {s}\n" ++
            "\n" ++
            "[malformed-microarchitectures]\n" ++
            "Server = https://one.example.invalid/$archv\n" ++
            "Server = https://two.example.invalid/$archvbad\n" ++
            "Server = https://three.example.invalid/$archv1\n" ++
            "Server = https://four.example.invalid/$arch\n",
        .{workspace.db_path},
    );
    defer allocator.free(config);

    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const architectures = try mgr.get_allowed_architecture();
    defer {
        for (architectures) |architecture| allocator.free(architecture);
        allocator.free(architectures);
    }

    try testing.expectEqual(@as(usize, 2), architectures.len);
}

test "purify removes an invalid package archive outside dry-run mode" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const cache_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/cache",
        .{workspace.root},
        0,
    );
    defer allocator.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);
    mgr.config.cache_directory = cache_path;

    const valid_source = try workspace.createPackageArchive(allocator, "valid-cache", "1.0-1");
    defer allocator.free(valid_source);
    const valid_path = try std.fmt.allocPrint(
        allocator,
        "{s}/valid-cache-1.0-1-any.pkg.tar",
        .{cache_path},
    );
    defer allocator.free(valid_path);
    try std.Io.Dir.rename(.cwd(), valid_source, .cwd(), valid_path, io);

    const corrupt_path = try std.fmt.allocPrint(
        allocator,
        "{s}/corrupt.pkg.tar.zst",
        .{cache_path},
    );
    defer allocator.free(corrupt_path);
    {
        var corrupt_file = try std.Io.Dir.cwd().createFile(io, corrupt_path, .{});
        defer corrupt_file.close(io);
        try corrupt_file.writeStreamingAll(io, "not a package archive");
    }

    const targets = try mgr.purify(false, false, true);
    defer {
        for (targets) |target| allocator.free(target);
        allocator.free(targets);
    }

    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqualStrings("corrupt.pkg.tar.zst", targets[0]);
    _ = try std.Io.Dir.cwd().statFile(io, valid_path, .{});
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, corrupt_path, .{}),
    );
}

test "get_allowed_architecture releases copied strings when list growth fails" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var failing = testing.FailingAllocator.init(arena.allocator(), .{
        .fail_index = 1,
    });

    const original_allocator = mgr.allocator;
    mgr.allocator = failing.allocator();
    defer mgr.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, mgr.get_allowed_architecture());
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

// ---------------------------------------------------------------------------
// Priority 4 configuration and presentation coverage
// ---------------------------------------------------------------------------

fn rawStringListContains(list: [*c]rawLibalpm.alpm_list_t, expected: []const u8) bool {
    var node = list;
    while (node != null) : (node = node.*.next) {
        const data = node.*.data orelse continue;
        const value = std.mem.span(@as([*c]const u8, @ptrCast(data)));
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn normalizedDirectory(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    return std.mem.trimEnd(u8, path, "/");
}

fn rawDirectoryListContains(list: [*c]rawLibalpm.alpm_list_t, expected: []const u8) bool {
    var node = list;
    while (node != null) : (node = node.*.next) {
        const data = node.*.data orelse continue;
        const value = std.mem.span(@as([*c]const u8, @ptrCast(data)));
        if (std.mem.eql(u8, normalizedDirectory(value), normalizedDirectory(expected))) return true;
    }
    return false;
}

test "Manager.init applies configured libalpm options and callback contexts" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/cache", .{workspace.root});
    defer allocator.free(cache_path);
    const hook_path = try std.fmt.allocPrint(allocator, "{s}/hooks", .{workspace.root});
    defer allocator.free(hook_path);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/manager.log", .{workspace.root});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);
    try std.Io.Dir.cwd().createDirPath(io, hook_path);

    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\n" ++
            "Architecture = test-architecture\n" ++
            "CacheDir = {s}\n" ++
            "HookDir = {s}\n" ++
            "LogFile = {s}\n" ++
            "DBPath = {s}\n" ++
            "IgnorePkg = hidden-package\n" ++
            "IgnoreGroup = hidden-group\n" ++
            "CheckSpace\n" ++
            "SigLevel = Required DatabaseOptional\n" ++
            "LocalFileSigLevel = Optional\n" ++
            "RemoteFileSigLevel = Required\n" ++
            "\n" ++
            "[configured-repository]\n" ++
            "Usage = Sync Search\n" ++
            "Server = https://mirror.example.invalid/$repo/os/$arch\n",
        .{ cache_path, hook_path, log_path, workspace.db_path },
    );
    defer allocator.free(config);

    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    var repository_names = try mgr.get_repository_names();
    defer repository_names.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), repository_names.items.len);
    try testing.expectEqualStrings("configured-repository", repository_names.items[0]);
    const configured_repository = mgr.find_configured_repository("configured-repository") orelse
        return error.TestFailed;
    try testing.expectEqualStrings("configured-repository", configured_repository.name);

    var configured_cache_directories = try mgr.get_configured_cache_directories();
    defer configured_cache_directories.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), configured_cache_directories.items.len);
    try testing.expectEqualStrings(
        normalizedDirectory(cache_path),
        normalizedDirectory(configured_cache_directories.items[0]),
    );

    try testing.expect(rawDirectoryListContains(rawLibalpm.alpm_option_get_cachedirs(mgr.handle), cache_path));
    try testing.expect(rawDirectoryListContains(rawLibalpm.alpm_option_get_hookdirs(mgr.handle), hook_path));
    try testing.expectEqualStrings(log_path, std.mem.span(rawLibalpm.alpm_option_get_logfile(mgr.handle)));
    try testing.expectEqual(@as(c_int, 1), rawLibalpm.alpm_option_get_checkspace(mgr.handle));
    try testing.expect(rawStringListContains(rawLibalpm.alpm_option_get_ignorepkgs(mgr.handle), "hidden-package"));
    try testing.expect(rawStringListContains(rawLibalpm.alpm_option_get_ignoregroups(mgr.handle), "hidden-group"));
    try testing.expect(rawStringListContains(rawLibalpm.alpm_option_get_architectures(mgr.handle), "test-architecture"));
    try testing.expect(rawStringListContains(rawLibalpm.alpm_option_get_architectures(mgr.handle), "any"));

    try testing.expect(rawLibalpm.alpm_option_get_fetchcb(mgr.handle) != null);
    try testing.expect(rawLibalpm.alpm_option_get_eventcb(mgr.handle) != null);
    try testing.expect(rawLibalpm.alpm_option_get_questioncb(mgr.handle) != null);
    try testing.expect(rawLibalpm.alpm_option_get_progresscb(mgr.handle) != null);
    try testing.expect(rawLibalpm.alpm_option_get_fetchcb_ctx(mgr.handle) == @as(?*anyopaque, @ptrCast(mgr)));
    try testing.expect(rawLibalpm.alpm_option_get_eventcb_ctx(mgr.handle) == @as(?*anyopaque, @ptrCast(mgr)));
    try testing.expect(rawLibalpm.alpm_option_get_questioncb_ctx(mgr.handle) == @as(?*anyopaque, @ptrCast(mgr)));
    try testing.expect(rawLibalpm.alpm_option_get_progresscb_ctx(mgr.handle) == @as(?*anyopaque, @ptrCast(mgr)));

    try testing.expectEqual(@as(usize, 1), mgr.sync_dbs.items.len);
    const database = mgr.sync_dbs.items[0];
    try testing.expectEqualStrings("configured-repository", database.name() orelse return error.TestFailed);

    var servers = database.servers();
    try testing.expectEqualStrings(
        "https://mirror.example.invalid/configured-repository/os/test-architecture",
        servers.next() orelse return error.TestFailed,
    );
    try testing.expect(servers.next() == null);

    var usage: c_int = 0;
    try testing.expectEqual(@as(c_int, 0), rawLibalpm.alpm_db_get_usage(database.ptr, &usage));
    try testing.expectEqual(rawLibalpm.ALPM_DB_USAGE_SYNC | rawLibalpm.ALPM_DB_USAGE_SEARCH, usage);
}

test "get_foreign_packages hides ignored packages until hidden packages are enabled" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-hidden-foreign", "1.0-1");

    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\n" ++
            "Architecture = auto\n" ++
            "SigLevel = Never\n" ++
            "DBPath = {s}\n" ++
            "IgnorePkg = shelly-hidden-foreign\n",
        .{workspace.db_path},
    );
    defer allocator.free(config);
    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    const hidden = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, hidden);
    try testing.expectEqual(@as(usize, 0), hidden.len);

    try testing.expect(mgr.toggle_hidden_packages());
    const visible = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, visible);
    try testing.expectEqual(@as(usize, 1), visible.len);
    try testing.expectEqualStrings(
        "shelly-hidden-foreign",
        visible[0].name() orelse return error.TestFailed,
    );
}

// ---------------------------------------------------------------------------
// Priority 5 owned-package lifetime and failure cleanup coverage
// ---------------------------------------------------------------------------

fn findOwnedPackage(packages: []const libalpm.OwnedPackage, expected_name: []const u8) ?*const libalpm.OwnedPackage {
    for (packages) |*package| {
        const name = package.name() orelse continue;
        if (std.mem.eql(u8, name, expected_name)) return package;
    }
    return null;
}

test "owned package results remain valid after Manager.deinit" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "local-only", "1.0-1");
    try workspace.addLocalPackage(allocator, "remote-provider", "1.0-1");
    try workspace.createSyncDatabase(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    var manager_alive = true;
    defer if (manager_alive) mgr.deinit();

    const installed = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, installed);
    const foreign = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, foreign);
    const available = try mgr.get_available_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, available);
    const updates = try mgr.get_updates_available();
    defer libalpm.OwnedPackageWithUpdate.deinitSlice(allocator, updates);

    mgr.deinit();
    manager_alive = false;

    try testing.expectEqual(@as(usize, 2), installed.len);
    const installed_local = findOwnedPackage(installed, "local-only") orelse return error.TestFailed;
    try testing.expectEqualStrings("1.0-1", installed_local.version() orelse return error.TestFailed);
    try testing.expectEqualStrings("local", installed_local.repository() orelse return error.TestFailed);

    try testing.expectEqual(@as(usize, 1), foreign.len);
    try testing.expectEqualStrings("local-only", foreign[0].name() orelse return error.TestFailed);

    try testing.expectEqual(@as(usize, 1), available.len);
    try testing.expectEqualStrings("remote-provider", available[0].name() orelse return error.TestFailed);
    try testing.expectEqualStrings("2.0-1", available[0].version() orelse return error.TestFailed);
    try testing.expectEqualStrings("seafoam-labs", available[0].repository() orelse return error.TestFailed);

    try testing.expectEqual(@as(usize, 1), updates.len);
    try testing.expectEqualStrings("remote-provider", updates[0].old_package.name() orelse return error.TestFailed);
    try testing.expectEqualStrings("1.0-1", updates[0].old_package.version() orelse return error.TestFailed);
    try testing.expectEqualStrings("remote-provider", updates[0].new_package.name() orelse return error.TestFailed);
    try testing.expectEqualStrings("2.0-1", updates[0].new_package.version() orelse return error.TestFailed);
}

const OwnedPackageOperation = enum {
    installed,
    foreign,
    available,
};

fn callOwnedPackageOperation(mgr: *Manager, comptime operation: OwnedPackageOperation) ![]libalpm.OwnedPackage {
    return switch (operation) {
        .installed => mgr.get_installed_packages(),
        .foreign => mgr.get_foreign_packages(),
        .available => mgr.get_available_packages(),
    };
}

fn expectOwnedPackageAllocationCleanup(mgr: *Manager, comptime operation: OwnedPackageOperation) !void {
    const original_allocator = mgr.allocator;
    defer mgr.allocator = original_allocator;

    var observed_failure = false;
    var observed_success = false;
    for (0..64) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        mgr.allocator = failing.allocator();

        if (callOwnedPackageOperation(mgr, operation)) |packages| {
            libalpm.OwnedPackage.deinitSlice(failing.allocator(), packages);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            observed_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            observed_failure = true;
        }
    }

    try testing.expect(observed_failure);
    try testing.expect(observed_success);
}

fn expectOwnedUpdateAllocationCleanup(mgr: *Manager) !void {
    const original_allocator = mgr.allocator;
    defer mgr.allocator = original_allocator;

    var observed_failure = false;
    var observed_success = false;
    for (0..64) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        mgr.allocator = failing.allocator();

        if (mgr.get_updates_available()) |updates| {
            libalpm.OwnedPackageWithUpdate.deinitSlice(failing.allocator(), updates);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            observed_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            observed_failure = true;
        }
    }

    try testing.expect(observed_failure);
    try testing.expect(observed_success);
}

test "owned package result builders release partial snapshots after allocation failure" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "local-only", "1.0-1");
    try workspace.addLocalPackage(allocator, "remote-provider", "1.0-1");
    try workspace.createSyncDatabase(allocator);

    const mgr = try Manager.init(allocator, testing.environ, workspace.config_path, false, null);
    defer mgr.deinit();

    try expectOwnedPackageAllocationCleanup(mgr, .installed);
    try expectOwnedPackageAllocationCleanup(mgr, .foreign);
    try expectOwnedPackageAllocationCleanup(mgr, .available);
    try expectOwnedUpdateAllocationCleanup(mgr);
}
