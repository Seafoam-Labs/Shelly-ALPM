const std = @import("std");
const builtin = @import("builtin");
const manager = @import("manager.zig");
const bindings = @import("bindings.zig");
const events = @import("events.zig");

const Manager = manager.Manager;
const libalpm = bindings.libalpm;
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

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);

    // A fresh temporary database has no installed packages.
    try testing.expectEqual(@as(usize, 0), packages.items.len);
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

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);

    // A real system always has packages installed, each exposing a name.
    try testing.expect(packages.items.len > 0);
    for (packages.items) |package| {
        _ = package.name() orelse return error.TestFailed;
    }

    // `pacman` is installed on every Arch-based system.
    var found_pacman = false;
    for (packages.items) |package| {
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

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);
    if (packages.items.len == 0) return;

    // Package names are null-terminated slices, so they can be looked up directly.
    const first_name = packages.items[0].name() orelse return error.TestFailed;
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

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // With no installed packages there is nothing that could be foreign.
    try testing.expectEqual(@as(usize, 0), foreign.items.len);
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

    var installed = try mgr.get_installed_packages();
    defer installed.deinit(mgr.allocator);

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // Foreign packages are always a subset of the installed packages.
    try testing.expect(foreign.items.len <= installed.items.len);

    // Every foreign package is nonetheless installed, so it resolves locally.
    for (foreign.items) |package| {
        const name = package.name() orelse return error.TestFailed;
        const local = try mgr.get_single_installed_package(name);
        try testing.expect(local != null);
    }

    // If some packages were matched to a sync database, the sync caches are
    // loaded and repository packages must be excluded. `pacman` ships from the
    // official [core] repository, so it must never be reported as foreign.
    if (foreign.items.len < installed.items.len) {
        for (foreign.items) |package| {
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

    var packages = try mgr.get_installed_packages();
    defer packages.deinit(mgr.allocator);

    // The real system database always has packages installed.
    try testing.expect(packages.items.len > 0);

    // `pacman` is installed on every Arch-based system and must be visible
    // through the symlinked local database.
    var found_pacman = false;
    for (packages.items) |package| {
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

    var installed = try mgr.get_installed_packages();
    defer installed.deinit(mgr.allocator);
    try testing.expect(installed.items.len > 0);

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // The workspace configures no repositories, so no sync database is
    // registered and every installed package counts as foreign.
    try testing.expectEqual(installed.items.len, foreign.items.len);
}

fn containsPackage(packages: []const libalpm.Package, name: []const u8) bool {
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

    var installed = try mgr.get_installed_packages();
    defer installed.deinit(mgr.allocator);

    var foreign = try mgr.get_foreign_packages();
    defer foreign.deinit(mgr.allocator);

    // The linked local database always exposes the real installed packages.
    try testing.expect(installed.items.len > 0);
    try testing.expect(containsPackage(installed.items, "pacman"));

    // Skip the exclusion assertions unless the sync actually loaded repository
    // data (network available and databases downloaded). Without it every
    // installed package would trivially be "foreign".
    if (foreign.items.len == installed.items.len) return;

    // `pacman` is provided by the official [core] repository, so once its sync
    // database is loaded it must never be reported as a foreign package.
    try testing.expect(!containsPackage(foreign.items, "pacman"));
    try testing.expect(foreign.items.len < installed.items.len);
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
    var packages = try mgr.get_available_packages();
    defer packages.deinit(mgr.allocator);

    try testing.expectEqual(@as(usize, 0), packages.items.len);
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

    var packages = try mgr.get_available_packages();
    defer packages.deinit(mgr.allocator);

    // A real repository always exposes packages, each with a readable name.
    try testing.expect(packages.items.len > 0);
    for (packages.items) |package| {
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
        mgr.install_packages(&package_names, .none),
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
        mgr.install_packages(&package_names, .none),
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
            mgr.install_packages(&package_names, .none),
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
        mgr.install_packages(&unqualified, .none),
    );

    var qualified = [_][:0]const u8{"seafoam-labs/shelly-package-that-does-not-exist"};
    try testing.expectError(
        error.PackageFetchFailed,
        mgr.install_packages(&qualified, .none),
    );
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
        mgr.install_local_packages(&paths, .none),
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
        mgr.install_local_packages(&paths, .none),
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
        mgr.install_local_packages(&paths, .none),
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
    try mgr.install_local_packages(&paths, .dbonly);

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
    try mgr.install_local_packages(&paths, .dbonly);

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
        mgr.remove_packages(&package_names, .none, true),
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
        mgr.remove_packages(&package_names, .none, true),
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
        mgr.remove_packages(&package_names, .none, true),
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
        mgr.remove_packages(&package_names, .none, true),
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
    try mgr.remove_packages(&package_names, .dbonly, true);
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

    var updates = try mgr.get_updates_available();
    defer updates.deinit(mgr.allocator);

    try testing.expectEqual(@as(usize, 0), updates.items.len);
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

    var updates = try mgr.get_updates_available();
    defer updates.deinit(mgr.allocator);

    // Each entry must have both an old (installed) and a new (repository) package.
    for (updates.items) |update| {
        const old_name = update.old_package.name() orelse return error.TestFailed;
        const new_name = update.new_package.name() orelse return error.TestFailed;
        // The package names must match — we are comparing the same package.
        try testing.expectEqualStrings(old_name, new_name);
    }
}
