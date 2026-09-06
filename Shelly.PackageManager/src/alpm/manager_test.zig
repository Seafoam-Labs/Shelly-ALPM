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

const CancelOnDownload = struct {
    context: *operations.OperationContext,
    saw_download: std.atomic.Value(bool) = .init(false),

    fn handle(data: ?*anyopaque, event: operations.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .started => |started| {
                if (started.envelope.backend != .download) return;
                self.saw_download.store(true, .release);
                self.context.cancel();
            },
            else => {},
        }
    }
};

const InitEventCapture = struct {
    started: usize = 0,
    failures: usize = 0,
    completed: usize = 0,
    completion_status: ?operations.CompletionStatus = null,
    saw_lock_message: bool = false,
    native_code: ?i64 = null,

    fn handle(data: ?*anyopaque, event: operations.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .started => |started| {
                if (started.envelope.backend != .alpm or
                    started.envelope.kind != .configure or
                    !std.mem.eql(u8, started.envelope.subject orelse "", "libalpm")) return;
                self.started += 1;
            },
            .failure => |failure| {
                self.failures += 1;
                self.saw_lock_message = std.mem.indexOf(
                    u8,
                    failure.message,
                    "unable to lock database",
                ) != null;
                self.native_code = failure.native_code;
            },
            .completed => |completed| {
                self.completed += 1;
                self.completion_status = completed.status;
            },
            else => {},
        }
    }
};

const RemoveEventCapture = struct {
    started: usize = 0,
    failures: usize = 0,
    completed: usize = 0,
    completion_status: ?operations.CompletionStatus = null,
    saw_lock_message: bool = false,

    fn matches(envelope: operations.Envelope) bool {
        return envelope.backend == .alpm and envelope.kind == .remove;
    }

    fn handle(data: ?*anyopaque, event: operations.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .started => |started| {
                if (!matches(started.envelope)) return;
                self.started += 1;
            },
            .failure => |failure| {
                if (!matches(failure.envelope)) return;
                self.failures += 1;
                self.saw_lock_message = std.mem.indexOf(
                    u8,
                    failure.message,
                    "unable to lock database",
                ) != null;
            },
            .completed => |completed| {
                if (!matches(completed.envelope)) return;
                self.completed += 1;
                self.completion_status = completed.status;
            },
            else => {},
        }
    }
};

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
        return self.addLocalPackageWithDependencyTypes(allocator, name, version, &.{}, &.{});
    }

    fn addLocalPackageWithDependencies(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        dependencies: []const []const u8,
    ) !void {
        return self.addLocalPackageWithDependencyTypes(allocator, name, version, dependencies, &.{});
    }

    fn addLocalPackageWithOptionalDependencies(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        optional_dependencies: []const []const u8,
    ) !void {
        return self.addLocalPackageWithDependencyTypes(allocator, name, version, &.{}, optional_dependencies);
    }

    fn addLocalPackageWithDependencyTypes(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        dependencies: []const []const u8,
        optional_dependencies: []const []const u8,
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
        const dependency_values = try std.mem.join(allocator, "\n", dependencies);
        defer allocator.free(dependency_values);
        const dependency_section = if (dependencies.len == 0)
            try allocator.dupe(u8, "")
        else
            try std.fmt.allocPrint(allocator, "%DEPENDS%\n{s}\n\n", .{dependency_values});
        defer allocator.free(dependency_section);
        const optional_dependency_values = try std.mem.join(allocator, "\n", optional_dependencies);
        defer allocator.free(optional_dependency_values);
        const optional_dependency_section = if (optional_dependencies.len == 0)
            try allocator.dupe(u8, "")
        else
            try std.fmt.allocPrint(allocator, "%OPTDEPENDS%\n{s}\n\n", .{optional_dependency_values});
        defer allocator.free(optional_dependency_section);
        const desc = try std.fmt.allocPrint(
            allocator,
            "%NAME%\n{s}\n\n" ++
                "%VERSION%\n{s}\n\n" ++
                "%DESC%\nTemporary package used by remove_packages tests\n\n" ++
                "%ARCH%\nany\n\n" ++
                "%REASON%\n0\n\n" ++
                "%VALIDATION%\nnone\n\n" ++
                "{s}" ++
                "{s}",
            .{ name, version, dependency_section, optional_dependency_section },
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

    fn createRequiredBySyncDatabase(self: *const SyncTestWorkspace, allocator: std.mem.Allocator) !void {
        const sync_dir = try std.fmt.allocPrint(allocator, "{s}/sync", .{self.db_path});
        defer allocator.free(sync_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, sync_dir);

        const database_path = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{sync_dir});
        defer allocator.free(database_path);

        const target_desc =
            "%FILENAME%\nremote-target-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nremote-target\n\n" ++
            "%BASE%\nremote-target\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nTarget for required-by query tests\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n";
        const consumer_desc =
            "%FILENAME%\nremote-consumer-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nremote-consumer\n\n" ++
            "%BASE%\nremote-consumer\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nConsumer for required-by query tests\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n" ++
            "%DEPENDS%\nremote-target>=1\n\n";

        var file = try std.Io.Dir.cwd().createFile(self.io, database_path, .{});
        defer file.close(self.io);
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buffer);
        var archive_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
        try archive_writer.writeFileBytes("remote-target-1.0-1/desc", target_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("remote-consumer-1.0-1/desc", consumer_desc, .{ .mode = 0o644 });
        try archive_writer.finishPedantically();
        try file_writer.interface.flush();
    }

    fn createPackageArchive(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
    ) ![]u8 {
        return self.createPackageArchiveWithDependencies(allocator, name, version, &.{});
    }

    fn createPackageArchiveWithDependencies(
        self: *const SyncTestWorkspace,
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        dependencies: []const []const u8,
    ) ![]u8 {
        const package_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}-{s}-any.pkg.tar",
            .{ self.root, name, version },
        );
        errdefer allocator.free(package_path);

        var dependency_lines: std.ArrayList(u8) = .empty;
        defer dependency_lines.deinit(allocator);
        for (dependencies) |dependency| {
            try dependency_lines.print(allocator, "depend = {s}\n", .{dependency});
        }

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
                "license = MIT\n" ++
                "{s}",
            .{ name, name, version, name, dependency_lines.items },
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
        const shadowing_provider_desc =
            "%FILENAME%\nalpha-provider-2.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nalpha-provider\n\n" ++
            "%BASE%\nalpha-provider\n\n" ++
            "%VERSION%\n2.0-1\n\n" ++
            "%DESC%\nProvider ordered before the literal package\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n" ++
            "%PROVIDES%\nliteral-target=2\n\n";
        const literal_desc =
            "%FILENAME%\nliteral-target-3.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nliteral-target\n\n" ++
            "%BASE%\nliteral-target\n\n" ++
            "%VERSION%\n3.0-1\n\n" ++
            "%DESC%\nLiteral package that must outrank providers\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n";
        const version_provider_desc =
            "%FILENAME%\nversion-provider-2.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nversion-provider\n\n" ++
            "%BASE%\nversion-provider\n\n" ++
            "%VERSION%\n2.0-1\n\n" ++
            "%DESC%\nProvider used when a literal package is too old\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n" ++
            "%PROVIDES%\nversioned-target=2\n\n";
        const old_literal_desc =
            "%FILENAME%\nversioned-target-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\nversioned-target\n\n" ++
            "%BASE%\nversioned-target\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nLiteral package below the requested version\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n";

        var file = try std.Io.Dir.cwd().createFile(self.io, database_path, .{});
        defer file.close(self.io);
        var write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buffer);
        var archive_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
        try archive_writer.writeFileBytes("remote-provider-2.0-1/desc", provider_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("alpha-provider-2.0-1/desc", shadowing_provider_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("literal-target-3.0-1/desc", literal_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("version-provider-2.0-1/desc", version_provider_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("versioned-target-1.0-1/desc", old_literal_desc, .{ .mode = 0o644 });
        try archive_writer.finishPedantically();
        try file_writer.interface.flush();
    }

    fn createOptionalDependencySyncDatabase(self: *const SyncTestWorkspace, allocator: std.mem.Allocator) !void {
        const sync_dir = try std.fmt.allocPrint(allocator, "{s}/sync", .{self.db_path});
        defer allocator.free(sync_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, sync_dir);

        const database_path = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{sync_dir});
        defer allocator.free(database_path);

        const parent_desc =
            "%FILENAME%\noptional-parent-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\noptional-parent\n\n" ++
            "%BASE%\noptional-parent\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nPackage with several optional dependencies\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n" ++
            "%OPTDEPENDS%\ninstalled-option: already installed\noptional-one: first new option\noptional-two>=1: second new option\n\n";
        const installed_desc =
            "%FILENAME%\ninstalled-option-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\ninstalled-option\n\n" ++
            "%BASE%\ninstalled-option\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nAlready installed option\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n";
        const first_desc =
            "%FILENAME%\noptional-one-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\noptional-one\n\n" ++
            "%BASE%\noptional-one\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nFirst new option\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n";
        const second_desc =
            "%FILENAME%\noptional-two-1.0-1-any.pkg.tar\n\n" ++
            "%NAME%\noptional-two\n\n" ++
            "%BASE%\noptional-two\n\n" ++
            "%VERSION%\n1.0-1\n\n" ++
            "%DESC%\nSecond new option\n\n" ++
            "%CSIZE%\n1\n\n" ++
            "%ISIZE%\n1\n\n" ++
            "%ARCH%\nany\n\n";

        var file = try std.Io.Dir.cwd().createFile(self.io, database_path, .{});
        defer file.close(self.io);
        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(self.io, &write_buffer);
        var archive_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
        try archive_writer.writeFileBytes("optional-parent-1.0-1/desc", parent_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("installed-option-1.0-1/desc", installed_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("optional-one-1.0-1/desc", first_desc, .{ .mode = 0o644 });
        try archive_writer.writeFileBytes("optional-two-1.0-1/desc", second_desc, .{ .mode = 0o644 });
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

/// A fully local repository fixture for database-signature synchronization.
/// Source files deliberately use restrictive modes so successful syncs prove
/// that destination permissions do not inherit either source modes or umask.
const SignatureSyncWorkspace = struct {
    io: std.Io,
    root: []const u8,
    config_path: []const u8,
    db_path: []const u8,
    mirror_path: []const u8,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        signature_level: []const u8,
        include_signature: bool,
    ) !SignatureSyncWorkspace {
        const anchor: u8 = 0;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&anchor));
        const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-signature-sync-test-{x}", .{prng.random().int(u32)});
        errdefer allocator.free(root);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/pacman.conf", .{root});
        errdefer allocator.free(config_path);
        const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
        errdefer allocator.free(db_path);
        const mirror_path = try std.fmt.allocPrint(allocator, "{s}/mirror", .{root});
        errdefer allocator.free(mirror_path);
        const gpg_path = try std.fmt.allocPrint(allocator, "{s}/gnupg", .{root});
        defer allocator.free(gpg_path);

        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        try std.Io.Dir.cwd().createDirPath(io, db_path);
        try std.Io.Dir.cwd().createDirPath(io, mirror_path);
        try std.Io.Dir.cwd().createDirPath(io, gpg_path);

        const database_path = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{mirror_path});
        defer allocator.free(database_path);
        {
            var file = try std.Io.Dir.cwd().createFile(io, database_path, .{});
            defer file.close(io);
            var write_buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &write_buffer);
            var archive_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
            try archive_writer.writeFileBytes(
                "fixture-1.0-1/desc",
                "%FILENAME%\nfixture-1.0-1-any.pkg.tar.zst\n\n" ++
                    "%NAME%\nfixture\n\n" ++
                    "%VERSION%\n1.0-1\n\n" ++
                    "%DESC%\nDatabase signature synchronization fixture\n\n" ++
                    "%CSIZE%\n1\n\n" ++
                    "%ISIZE%\n1\n\n" ++
                    "%ARCH%\nany\n\n",
                .{ .mode = 0o644 },
            );
            try archive_writer.finishPedantically();
            try file_writer.interface.flush();
            try file.setPermissions(io, .fromMode(0o600));
        }

        if (include_signature) {
            const signature_path = try std.fmt.allocPrint(allocator, "{s}.sig", .{database_path});
            defer allocator.free(signature_path);
            var signature = try std.Io.Dir.cwd().createFile(io, signature_path, .{});
            defer signature.close(io);
            try signature.writeStreamingAll(io, "deliberately-invalid-detached-signature");
            try signature.setPermissions(io, .fromMode(0o600));
        }

        const config = try std.fmt.allocPrint(
            allocator,
            "[options]\n" ++
                "Architecture = x86_64\n" ++
                "DBPath = {s}\n" ++
                "GPGDir = {s}\n" ++
                "SigLevel = {s}\n" ++
                "\n" ++
                "[seafoam-labs]\n" ++
                "Server = file://{s}\n",
            .{ db_path, gpg_path, signature_level, mirror_path },
        );
        defer allocator.free(config);
        var config_file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);

        return .{
            .io = io,
            .root = root,
            .config_path = config_path,
            .db_path = db_path,
            .mirror_path = mirror_path,
        };
    }

    fn syncPath(self: *const SignatureSyncWorkspace, allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/sync/seafoam-labs.db{s}", .{ self.db_path, suffix });
    }

    fn cleanup(self: *SignatureSyncWorkspace, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        allocator.free(self.mirror_path);
        allocator.free(self.db_path);
        allocator.free(self.config_path);
        allocator.free(self.root);
    }
};

test "optional database signatures are retained beside world-readable databases" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Required DatabaseOptional", true);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    try mgr.sync_for_update_check(true);

    const database_path = try workspace.syncPath(allocator, "");
    defer allocator.free(database_path);
    const signature_path = try workspace.syncPath(allocator, ".sig");
    defer allocator.free(signature_path);
    const database_stat = try std.Io.Dir.cwd().statFile(io, database_path, .{});
    const signature_stat = try std.Io.Dir.cwd().statFile(io, signature_path, .{});
    try testing.expectEqual(@as(u32, 0o644), database_stat.permissions.toMode() & 0o7777);
    try testing.expectEqual(@as(u32, 0o644), signature_stat.permissions.toMode() & 0o7777);

    const sync_directory = try std.fmt.allocPrint(allocator, "{s}/sync", .{workspace.db_path});
    defer allocator.free(sync_directory);
    const directory_stat = try std.Io.Dir.cwd().statFile(io, sync_directory, .{});
    try testing.expectEqual(@as(u32, 0o755), directory_stat.permissions.toMode() & 0o7777);
}

test "optional missing database signature succeeds and removes a stale sibling" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Required DatabaseOptional", false);
    defer workspace.cleanup(allocator);

    const sync_directory = try std.fmt.allocPrint(allocator, "{s}/sync", .{workspace.db_path});
    defer allocator.free(sync_directory);
    try std.Io.Dir.cwd().createDirPath(io, sync_directory);
    try std.Io.Dir.cwd().setFilePermissions(io, sync_directory, .fromMode(0o700), .{});
    const signature_path = try workspace.syncPath(allocator, ".sig");
    defer allocator.free(signature_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = signature_path, .data = "stale-signature" });

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    try mgr.sync_for_update_check(true);

    const database_path = try workspace.syncPath(allocator, "");
    defer allocator.free(database_path);
    const database_stat = try std.Io.Dir.cwd().statFile(io, database_path, .{});
    try testing.expectEqual(@as(u32, 0o644), database_stat.permissions.toMode() & 0o7777);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, signature_path, .{}));
    const directory_stat = try std.Io.Dir.cwd().statFile(io, sync_directory, .{});
    try testing.expectEqual(@as(u32, 0o755), directory_stat.permissions.toMode() & 0o7777);
}

test "required missing database signature fails without leaving a database" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Required", false);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    try testing.expectError(error.UpdateFetchFailed, mgr.sync_for_update_check(true));

    const database_path = try workspace.syncPath(allocator, "");
    defer allocator.free(database_path);
    const signature_path = try workspace.syncPath(allocator, ".sig");
    defer allocator.free(signature_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, database_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, signature_path, .{}));
}

test "invalid optional database signature is fatal and cleaned up" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Required DatabaseOptional", true);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    try testing.expectError(error.SyncDbFailed, mgr.sync(true));

    const database_path = try workspace.syncPath(allocator, "");
    defer allocator.free(database_path);
    const signature_path = try workspace.syncPath(allocator, ".sig");
    defer allocator.free(signature_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, database_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, signature_path, .{}));
}

test "Manager.init registers the configured sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    try testing.expect(mgr.is_initialized);
    try testing.expect(mgr.handle != null);
    // applyConfig must have registered the [core] repository as a sync db.
    try testing.expect(mgr.sync_dbs.items.len >= 1);
}

test "Manager.init emits a successful configure operation when a context is provided" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var operation_context = operations.OperationContext.init(allocator, threaded.io());
    defer operation_context.deinit();
    var capture: InitEventCapture = .{};
    const subscription = try operation_context.subscribe(.{
        .function = InitEventCapture.handle,
        .data = &capture,
    });
    defer _ = operation_context.unsubscribe(subscription);

    var workspace = try SyncTestWorkspace.create(allocator, threaded.io());
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{
        .config_path = workspace.config_path,
        .operation_context = &operation_context,
    });
    defer mgr.deinit();

    try testing.expect(mgr.operation_context == &operation_context);
    try testing.expectEqual(@as(usize, 1), capture.started);
    try testing.expectEqual(@as(usize, 0), capture.failures);
    try testing.expectEqual(@as(usize, 1), capture.completed);
    try testing.expectEqual(operations.CompletionStatus.success, capture.completion_status.?);
}

test "remove_packages emits the database lock failure through its operation context" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var operation_context = operations.OperationContext.init(allocator, io);
    defer operation_context.deinit();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-lock-test", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, .{
        .config_path = workspace.config_path,
        .operation_context = &operation_context,
    });
    defer mgr.deinit();

    var capture: RemoveEventCapture = .{};
    const subscription = try operation_context.subscribe(.{
        .function = RemoveEventCapture.handle,
        .data = &capture,
    });
    defer _ = operation_context.unsubscribe(subscription);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/db.lck", .{workspace.db_path});
    defer allocator.free(lock_path);
    var lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{});
    lock_file.close(io);

    var package_names = [_][:0]const u8{"shelly-lock-test"};
    try testing.expectError(
        error.TransInitFailed,
        mgr.remove_packages(&package_names, .{ .dbonly = true }, true),
    );

    try testing.expectEqual(@as(usize, 1), capture.started);
    try testing.expectEqual(@as(usize, 1), capture.failures);
    try testing.expect(capture.saw_lock_message);
    try testing.expectEqual(@as(usize, 1), capture.completed);
    try testing.expectEqual(operations.CompletionStatus.failed, capture.completion_status.?);
}

test "Manager.init rejects a temp root that aliases DBPath without deleting the local database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-alias-guard", "1.0-1");

    try testing.expectError(
        error.InitFailed,
        Manager.init(
            allocator,
            testing.environ,
            .{ .config_path = workspace.config_path, .temp_root_path = workspace.db_path },
        ),
    );

    const desc_path = try std.fmt.allocPrint(
        allocator,
        "{s}/local/shelly-alias-guard-1.0-1/desc",
        .{workspace.db_path},
    );
    defer allocator.free(desc_path);
    _ = try std.Io.Dir.cwd().statFile(io, desc_path, .{});
}

test "Manager.sync downloads the configured database into DBPath/sync" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Never", false);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    // Force the download so the result never depends on a pre-existing cache.
    try mgr.sync(true);

    // sync creates "<DBPath>/sync" and stores the configured database there.
    const sync_dir = try std.fmt.allocPrint(allocator, "{s}/sync", .{workspace.db_path});
    defer allocator.free(sync_dir);
    _ = try std.Io.Dir.cwd().statFile(io, sync_dir, .{});

    const core_db = try std.fmt.allocPrint(allocator, "{s}/seafoam-labs.db", .{sync_dir});
    defer allocator.free(core_db);
    const stat = try std.Io.Dir.cwd().statFile(io, core_db, .{});
    try testing.expect(stat.size > 0);
}

test "Manager.sync exposes cancellable logical database downloads during mirror failover" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    var context = operations.OperationContext.init(allocator, io);
    defer context.deinit();
    var cancel_download: CancelOnDownload = .{ .context = &context };
    _ = try context.subscribe(.{ .function = CancelOnDownload.handle, .data = &cancel_download });
    mgr.setOperationContext(&context);

    try testing.expectError(error.UpdateFetchFailed, mgr.sync(true));
    try testing.expect(cancel_download.saw_download.load(.acquire));
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-installed-query", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const result = try mgr.get_single_installed_package("shelly-installed-query");
    const pkg = result orelse return error.TestFailed;

    const name = pkg.name() orelse return error.TestFailed;
    try testing.expectEqualStrings("shelly-installed-query", name);
}

// ---------------------------------------------------------------------------
// get_required_packages
// ---------------------------------------------------------------------------

fn deinitRequiredPackageNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |name| allocator.free(name);
    if (names.len != 0) allocator.free(names);
}

fn containsRequiredPackage(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

test "get_required_packages returns NoHandle when the handle is null" {
    var mgr: Manager = undefined;
    mgr.handle = null;

    try testing.expectError(error.NoHandle, mgr.get_required_packages("target", "local"));
}

test "get_required_packages rejects empty package and database names" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    try testing.expectError(error.NoPackageFound, mgr.get_required_packages("", "local"));
    try testing.expectError(error.NoPackageFound, mgr.get_required_packages("target", ""));
}

test "get_required_packages returns owned local reverse dependencies" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-required-target", "1.0-1");
    try workspace.addLocalPackageWithDependencies(
        allocator,
        "shelly-required-first",
        "1.0-1",
        &.{"shelly-required-target>=1"},
    );
    try workspace.addLocalPackageWithDependencies(
        allocator,
        "shelly-required-second",
        "1.0-1",
        &.{"shelly-required-target"},
    );
    try workspace.addLocalPackageWithDependencies(
        allocator,
        "shelly-unrelated",
        "1.0-1",
        &.{"another-target"},
    );

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const required = try mgr.get_required_packages("SHELLY-REQUIRED-TARGET", "LOCAL");
    defer deinitRequiredPackageNames(allocator, required);

    try testing.expectEqual(@as(usize, 2), required.len);
    try testing.expect(containsRequiredPackage(required, "shelly-required-first"));
    try testing.expect(containsRequiredPackage(required, "shelly-required-second"));
    try testing.expect(!containsRequiredPackage(required, "shelly-unrelated"));
}

test "Package owned reverse dependency queries return local required and optional names" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-reverse-target", "1.0-1");
    try workspace.addLocalPackageWithDependencies(
        allocator,
        "shelly-required-consumer",
        "1.0-1",
        &.{"shelly-reverse-target>=1"},
    );
    try workspace.addLocalPackageWithOptionalDependencies(
        allocator,
        "shelly-optional-first",
        "1.0-1",
        &.{"shelly-reverse-target: Optional target support"},
    );
    try workspace.addLocalPackageWithOptionalDependencies(
        allocator,
        "shelly-optional-second",
        "1.0-1",
        &.{"shelly-reverse-target"},
    );
    try workspace.addLocalPackageWithOptionalDependencies(
        allocator,
        "shelly-optional-unrelated",
        "1.0-1",
        &.{"another-target: Unrelated support"},
    );

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const target = (try mgr.get_single_installed_package("shelly-reverse-target")) orelse
        return error.TestFailed;
    const required_by = try target.owned_required_by(allocator);
    defer deinitRequiredPackageNames(allocator, required_by);
    const optional_for = try target.owned_optional_for(allocator);
    defer deinitRequiredPackageNames(allocator, optional_for);

    try testing.expectEqual(@as(usize, 1), required_by.len);
    try testing.expect(containsRequiredPackage(required_by, "shelly-required-consumer"));
    try testing.expectEqual(@as(usize, 2), optional_for.len);
    try testing.expect(containsRequiredPackage(optional_for, "shelly-optional-first"));
    try testing.expect(containsRequiredPackage(optional_for, "shelly-optional-second"));
    try testing.expect(!containsRequiredPackage(optional_for, "shelly-optional-unrelated"));
}

test "installed package snapshots selectively include direct reverse dependencies" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-snapshot-target", "1.0-1");
    try workspace.addLocalPackageWithDependencies(
        allocator,
        "shelly-snapshot-direct",
        "1.0-1",
        &.{"shelly-snapshot-target"},
    );
    try workspace.addLocalPackageWithDependencies(
        allocator,
        "shelly-snapshot-indirect",
        "1.0-1",
        &.{"shelly-snapshot-direct"},
    );
    try workspace.addLocalPackageWithOptionalDependencies(
        allocator,
        "shelly-snapshot-optional",
        "1.0-1",
        &.{"shelly-snapshot-target: Optional integration"},
    );

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const default_packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, default_packages);
    const default_target = findOwnedPackage(default_packages, "shelly-snapshot-target") orelse
        return error.TestFailed;
    try testing.expectEqual(@as(usize, 0), default_target.required_by().len);
    try testing.expectEqual(@as(usize, 0), default_target.optional_for().len);

    const required_packages = try mgr.get_installed_packages_with_reverse_dependencies(.{
        .required_by = true,
    });
    defer libalpm.OwnedPackage.deinitSlice(allocator, required_packages);
    const required_target = findOwnedPackage(required_packages, "shelly-snapshot-target") orelse
        return error.TestFailed;
    try testing.expect(containsReversePackage(required_target.required_by(), "shelly-snapshot-direct"));
    try testing.expect(!containsReversePackage(required_target.required_by(), "shelly-snapshot-indirect"));
    try testing.expectEqual(@as(usize, 0), required_target.optional_for().len);

    const optional_packages = try mgr.get_installed_packages_with_reverse_dependencies(.{
        .optional_for = true,
    });
    defer libalpm.OwnedPackage.deinitSlice(allocator, optional_packages);
    const optional_target = findOwnedPackage(optional_packages, "shelly-snapshot-target") orelse
        return error.TestFailed;
    try testing.expectEqual(@as(usize, 0), optional_target.required_by().len);
    try testing.expect(containsReversePackage(optional_target.optional_for(), "shelly-snapshot-optional"));

    const both_packages = try mgr.get_installed_packages_with_reverse_dependencies(.{
        .required_by = true,
        .optional_for = true,
    });
    defer libalpm.OwnedPackage.deinitSlice(allocator, both_packages);
    const both_target = findOwnedPackage(both_packages, "shelly-snapshot-target") orelse
        return error.TestFailed;
    try testing.expect(containsReversePackage(both_target.required_by(), "shelly-snapshot-direct"));
    try testing.expect(containsReversePackage(both_target.optional_for(), "shelly-snapshot-optional"));
}

fn containsReversePackage(names: anytype, expected: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

test "get_required_packages returns an empty result for an unknown package" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const required = try mgr.get_required_packages("missing-package", "local");
    defer deinitRequiredPackageNames(allocator, required);
    try testing.expectEqual(@as(usize, 0), required.len);
}

test "get_required_packages rejects an unknown sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    try testing.expectError(
        error.DatabaseReadFailed,
        mgr.get_required_packages("target", "missing-repository"),
    );
}

test "get_required_packages resolves a named sync database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.createRequiredBySyncDatabase(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const required = try mgr.get_required_packages("remote-target", "SEAFOAM-LABS");
    defer deinitRequiredPackageNames(allocator, required);

    try testing.expectEqual(@as(usize, 1), required.len);
    try testing.expectEqualStrings("remote-consumer", required[0]);
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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
    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    mgr.setOperationContext(&context);

    context.cancel();
    try testing.expectError(error.Cancelled, mgr.get_installed_packages());
}

test "get_installed_packages lists packages from a temporary database" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-installed-first", "1.0-1");
    try workspace.addLocalPackage(allocator, "shelly-installed-second", "2.0-1");

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    try testing.expectEqual(@as(usize, 2), packages.len);
    try testing.expect(containsPackage(packages, "shelly-installed-first"));
    try testing.expect(containsPackage(packages, "shelly-installed-second"));
}

test "get_single_installed_package matches an entry from get_installed_packages" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "shelly-installed-match", "1.0-1");

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const packages = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);
    try testing.expectEqual(@as(usize, 1), packages.len);

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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "local-only", "1.0-1");
    try workspace.addLocalPackage(allocator, "remote-provider", "1.0-1");
    try workspace.createSyncDatabase(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const installed = try mgr.get_installed_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, installed);

    const foreign = try mgr.get_foreign_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, foreign);

    try testing.expectEqual(@as(usize, 2), installed.len);
    try testing.expectEqual(@as(usize, 1), foreign.len);
    try testing.expect(containsPackage(foreign, "local-only"));
    try testing.expect(!containsPackage(foreign, "remote-provider"));
}

test "refresh reloads an externally replaced sync database cache" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.createSyncDatabase(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const original = try allocator.dupeZ(u8, "remote-provider");
    defer allocator.free(original);
    const replacement = try allocator.dupeZ(u8, "remote-target");
    defer allocator.free(replacement);

    // Materialize the first archive in libalpm's sync package cache.
    try testing.expectEqualStrings("remote-provider", try mgr.find_remote_satisfier_for_dependency(original));
    try testing.expectError(error.PkgNotFound, mgr.find_remote_satisfier_for_dependency(replacement));

    // Shelly's downloader replaces repository archives outside alpm_db_update,
    // so the live handle continues to expose the old cache until refresh.
    try workspace.createRequiredBySyncDatabase(allocator);
    try testing.expectEqualStrings("remote-provider", try mgr.find_remote_satisfier_for_dependency(original));
    try testing.expectError(error.PkgNotFound, mgr.find_remote_satisfier_for_dependency(replacement));

    try mgr.refresh();
    try testing.expectError(error.PkgNotFound, mgr.find_remote_satisfier_for_dependency(original));
    try testing.expectEqualStrings("remote-target", try mgr.find_remote_satisfier_for_dependency(replacement));
}

test "refresh reports a detailed reinitialization failure" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    var capture: ErrorCapture = .{};
    const error_handler = try mgr.dispatcher.addErrorHandler(.{
        .function = captureError,
        .data = &capture,
    });
    defer mgr.dispatcher.removeErrorHandler(error_handler);

    // A regular file cannot contain libalpm's database hierarchy.
    mgr.config.database_path = "/dev/null/shelly-refresh-test";
    try testing.expectError(error.RefreshFailed, mgr.refresh());
    try testing.expect(std.mem.indexOf(
        u8,
        capture.text(),
        "Failed to reinitialize ALPM while reloading package databases",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, capture.text(), "ALPM operation failed") == null);
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path, .temp_root_path = workspace.root });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path, .temp_root_path = workspace.root });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path, .temp_root_path = workspace.root });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path, .temp_root_path = workspace.root });
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
    const mgr = Manager.init(allocator, testing.environ, .{ .config_path = sys_config, .temp_root_path = temp_root }) catch return;
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Never", false);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    // Download the remote database so packages become available.
    try mgr.sync(true);

    const packages = try mgr.get_available_packages();
    defer libalpm.OwnedPackage.deinitSlice(allocator, packages);

    // The local fixture exposes one package with a readable name.
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    var context = operations.OperationContext.init(allocator, io);
    defer context.deinit();
    var cancel_download: CancelOnDownload = .{ .context = &context };
    _ = try context.subscribe(.{ .function = CancelOnDownload.handle, .data = &cancel_download });
    mgr.setOperationContext(&context);

    var package_names = [_][:0]const u8{"remote-provider"};
    try testing.expectError(
        error.UpdateFetchFailed,
        mgr.install_packages(&package_names, .{}),
    );
    try testing.expect(cancel_download.saw_download.load(.acquire));
}

test "install_packages exposes its prepared plan and decline prevents downloads" {
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
        "[options]\nArchitecture = auto\nSigLevel = Never\nDBPath = {s}\nCacheDir = {s}\n\n" ++
            "[seafoam-labs]\nServer = file://{s}/mirror\n",
        .{ workspace.db_path, cache_path, workspace.root },
    );
    defer allocator.free(config);
    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    const Capture = struct {
        saw_plan: bool = false,
        package_count: usize = 0,
        download_size: ?u64 = null,

        fn answer(data: ?*anyopaque, question: operations.Question) operations.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (question.kind != .confirm_transaction) return .accepted;
            const plan = question.transaction_plan orelse return .declined;
            self.saw_plan = true;
            self.package_count = plan.packages.len;
            if (plan.packages.len > 0) {
                testing.expectEqualStrings("remote-provider", plan.packages[0].name) catch unreachable;
                testing.expectEqual(operations.TransactionPackageRole.requested, plan.packages[0].role) catch unreachable;
                self.download_size = plan.packages[0].download_size;
            }
            return .declined;
        }
    };
    var capture: Capture = .{};
    var context = operations.OperationContext.init(allocator, io);
    defer context.deinit();
    context.setQuestionHandler(.{ .function = Capture.answer, .data = &capture });
    mgr.setOperationContext(&context);

    var package_names = [_][:0]const u8{"remote-provider"};
    try testing.expectError(error.Cancelled, mgr.install_packages(&package_names, .{}));
    try testing.expect(capture.saw_plan);
    try testing.expectEqual(@as(usize, 1), capture.package_count);
    try testing.expectEqual(@as(?u64, 1), capture.download_size);
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/remote-provider-2.0-1-any.pkg.tar", .{cache_path});
    defer allocator.free(archive_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, archive_path, .{}));
}

test "install_packages preserves every optional dependency selection after an installed first choice" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.addLocalPackage(allocator, "installed-option", "1.0-1");
    try workspace.createOptionalDependencySyncDatabase(allocator);
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/cache", .{workspace.root});
    defer allocator.free(cache_path);
    try std.Io.Dir.cwd().createDirPath(io, cache_path);
    const config = try std.fmt.allocPrint(
        allocator,
        "[options]\nArchitecture = auto\nSigLevel = Never\nDBPath = {s}\nCacheDir = {s}\n\n" ++
            "[seafoam-labs]\nServer = file://{s}/mirror\n",
        .{ workspace.db_path, cache_path, workspace.root },
    );
    defer allocator.free(config);
    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();
    const Capture = struct {
        saw_optional_question: bool = false,
        saw_plan: bool = false,

        fn answer(data: ?*anyopaque, question: operations.Question) operations.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (question.kind == .select_optional_dependencies) {
                testing.expectEqual(@as(usize, 3), question.options.len) catch unreachable;
                testing.expectEqualStrings("installed-option", question.options[0].id) catch unreachable;
                testing.expect(question.options[0].is_installed) catch unreachable;
                self.saw_optional_question = true;
                return .{ .choices = &.{ 0, 1, 2 } };
            }
            if (question.kind != .confirm_transaction) return .accepted;

            const plan = question.transaction_plan orelse return .declined;
            var saw_parent = false;
            var saw_first = false;
            var saw_second = false;
            for (plan.packages) |package| {
                if (std.mem.eql(u8, package.name, "optional-parent")) {
                    testing.expectEqual(operations.TransactionPackageRole.requested, package.role) catch unreachable;
                    saw_parent = true;
                } else if (std.mem.eql(u8, package.name, "optional-one")) {
                    testing.expectEqual(operations.TransactionPackageRole.optional_dependency, package.role) catch unreachable;
                    saw_first = true;
                } else if (std.mem.eql(u8, package.name, "optional-two")) {
                    testing.expectEqual(operations.TransactionPackageRole.optional_dependency, package.role) catch unreachable;
                    saw_second = true;
                } else if (std.mem.eql(u8, package.name, "installed-option")) {
                    unreachable;
                }
            }
            testing.expectEqual(@as(usize, 3), plan.packages.len) catch unreachable;
            testing.expect(saw_parent and saw_first and saw_second) catch unreachable;
            self.saw_plan = true;
            return .declined;
        }
    };
    var capture: Capture = .{};
    var context = operations.OperationContext.init(allocator, io);
    defer context.deinit();
    context.setQuestionHandler(.{ .function = Capture.answer, .data = &capture });
    mgr.setOperationContext(&context);

    var package_names = [_][:0]const u8{"optional-parent"};
    try testing.expectError(error.Cancelled, mgr.install_packages(&package_names, .{}));
    try testing.expect(capture.saw_optional_question);
    try testing.expect(capture.saw_plan);
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

test "install_local_packages predownloads repository dependencies before commit" {
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);
    try workspace.createSyncDatabase(allocator);

    const provider_path = try workspace.createPackageArchive(allocator, "remote-provider", "2.0-1");
    defer allocator.free(provider_path);

    const local_path = try workspace.createPackageArchiveWithDependencies(
        allocator,
        "aur-style-package",
        "1.0-1",
        &.{"remote-provider"},
    );
    defer allocator.free(local_path);

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
            "Server = file://{s}\n",
        .{ workspace.db_path, cache_path, workspace.root },
    );
    defer allocator.free(config);
    {
        var config_file = try std.Io.Dir.cwd().createFile(io, workspace.config_path, .{});
        defer config_file.close(io);
        try config_file.writeStreamingAll(io, config);
    }

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    const UnexpectedFetchCapture = struct {
        saw_unexpected_fetch: bool = false,

        fn capture(data: ?*anyopaque, args: events.ErrorArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (std.mem.indexOf(u8, args.message, "Unexpected libalpm fetch request") != null) {
                self.saw_unexpected_fetch = true;
            }
        }
    };
    var capture: UnexpectedFetchCapture = .{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = UnexpectedFetchCapture.capture, .data = &capture });

    var paths = [_][]const u8{local_path};
    try mgr.install_local_packages(&paths, .{ .downloadonly = true });

    const cached_provider = try std.fmt.allocPrint(allocator, "{s}/remote-provider-2.0-1-any.pkg.tar", .{cache_path});
    defer allocator.free(cached_provider);
    _ = try std.Io.Dir.cwd().statFile(io, cached_provider, .{});
    try testing.expect(!capture.saw_unexpected_fetch);
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    var capture = ErrorCapture{};
    _ = try mgr.dispatcher.addErrorHandler(.{ .function = captureError, .data = @ptrCast(&capture) });

    var package_names = [_][:0]const u8{"shelly-package-that-does-not-exist"};
    try testing.expectError(
        error.NoPackageFound,
        mgr.remove_packages(&package_names, .{}, true),
    );
    try testing.expectEqualStrings("Could not remove \"shelly-package-that-does-not-exist\" because it is not installed. Check the package name and try again.", capture.text());
}

test "remove_packages cancels removal of a held package without confirmation" {
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var workspace = try SyncTestWorkspace.create(allocator, io);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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
    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    var workspace = try SignatureSyncWorkspace.create(allocator, io, "Never", false);
    defer workspace.cleanup(allocator);

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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
    const mgr = Manager.init(allocator, testing.environ, .{ .config_path = "/etc/pacman.conf", .temp_root_path = temp_root }) catch return;
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const literal_satisfier = try mgr.find_remote_satisfier_for_dependency_details("literal-target");
    try testing.expectEqualStrings("literal-target", literal_satisfier.real_name);
    try testing.expect(!literal_satisfier.via_provides);

    const versioned_literal = try mgr.find_remote_satisfier_for_dependency_details("literal-target>=3");
    try testing.expectEqualStrings("literal-target", versioned_literal.real_name);
    try testing.expect(!versioned_literal.via_provides);

    const fallback_provider = try mgr.find_remote_satisfier_for_dependency_details("versioned-target>=2");
    try testing.expectEqualStrings("version-provider", fallback_provider.real_name);
    try testing.expect(fallback_provider.via_provides);

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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    mgr.disable_transaction_hooks();
    try testing.expect(!rawDirectoryListContains(rawLibalpm.alpm_option_get_hookdirs(mgr.handle), hook_path));
    try testing.expect(rawDirectoryListContains(
        rawLibalpm.alpm_option_get_hookdirs(mgr.handle),
        "/nonexistent/shelly-no-hooks",
    ));
    try mgr.refresh();
    try testing.expect(!rawDirectoryListContains(rawLibalpm.alpm_option_get_hookdirs(mgr.handle), hook_path));
    try testing.expect(rawDirectoryListContains(
        rawLibalpm.alpm_option_get_hookdirs(mgr.handle),
        "/nonexistent/shelly-no-hooks",
    ));
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
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

    const available_remote = findOwnedPackage(available, "remote-provider") orelse return error.TestFailed;
    try testing.expectEqualStrings("2.0-1", available_remote.version() orelse return error.TestFailed);
    try testing.expectEqualStrings("seafoam-labs", available_remote.repository() orelse return error.TestFailed);

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

    const mgr = try Manager.init(allocator, testing.environ, .{ .config_path = workspace.config_path });
    defer mgr.deinit();

    try expectOwnedPackageAllocationCleanup(mgr, .installed);
    try expectOwnedPackageAllocationCleanup(mgr, .foreign);
    try expectOwnedPackageAllocationCleanup(mgr, .available);
    try expectOwnedUpdateAllocationCleanup(mgr);
}
