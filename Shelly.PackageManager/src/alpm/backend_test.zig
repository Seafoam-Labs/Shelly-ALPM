const std = @import("std");
const worker_fixture = @import("worker_fixture");
const pm = @import("PackageManager");
const t = std.testing;

const Fixture = struct {
    temp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    options: pm.Manager.InitOptions,
    archive: []const u8,
    fn init(backend: pm.Manager.Backend) !Fixture {
        var temp = t.tmpDir(.{});
        errdefer temp.cleanup();
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const io = t.io;
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try a.dupe(u8, buffer[0..try temp.dir.realPath(io, &buffer)]);
        for ([_][]const u8{ "root", "db", "cache", "gpg", "hooks" }) |dir| try temp.dir.createDirPath(io, dir);
        try temp.dir.writeFile(io, .{ .sub_path = "pacman.conf", .data = "[options]\nArchitecture = auto\nSigLevel = Never\nLocalFileSigLevel = Never\n" });
        var file = try temp.dir.createFile(io, "fixture.pkg.tar", .{});
        defer file.close(io);
        var out: [4096]u8 = undefined;
        var writer = file.writer(io, &out);
        var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
        try tar.writeFileBytes(".PKGINFO", "pkgname = backend-fixture\npkgver = 1-1\npkgdesc = Native backend fixture\narch = any\nsize = 8\nprovides = fixture-provider=1\n", .{ .mode = 0o644 });
        try tar.writeFileBytes("usr/share/backend-fixture", "fixture\n", .{ .mode = 0o644 });
        try tar.finishPedantically();
        try writer.interface.flush();
        const archive_path = try std.fs.path.join(a, &.{ path, "fixture.pkg.tar" });
        const options: pm.Manager.InitOptions = .{
            .backend = backend,
            .worker_executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, worker_fixture.path, a),
            .config_path = try std.fs.path.join(a, &.{ path, "pacman.conf" }),
            .root_directory = try std.fs.path.join(a, &.{ path, "root" }),
            .database_path = try std.fs.path.join(a, &.{ path, "db" }),
            .cache_directory = try std.fs.path.join(a, &.{ path, "cache" }),
            .gpg_directory = try std.fs.path.join(a, &.{ path, "gpg" }),
            .log_file = try std.fs.path.join(a, &.{ path, "log" }),
            .root_hooks_only = true,
        };
        return .{ .temp = temp, .arena = arena, .archive = archive_path, .options = options };
    }
    fn deinit(self: *Fixture) void {
        self.temp.cleanup();
        self.arena.deinit();
    }
    fn manager(self: *Fixture) !*pm.Manager {
        return pm.Manager.init(t.allocator, t.environ, self.options);
    }
};

test "native backend explicit unavailable selection fails before opening configuration" {
    if (pm.Manager.libalpm_enabled) return;
    try t.expectError(error.BackendUnavailable, pm.Manager.init(t.allocator, t.environ, .{ .backend = .libalpm, .config_path = "/nonexistent/config" }));
}

test "native backend RLPM provisions pacman libalpm and transitive ABI providers in private roots" {
    const Requirement = struct {
        dependency: [:0]const u8,
        supplier: []const u8,
        provides: []const u8 = "",
    };
    for ([_]Requirement{
        .{ .dependency = "pacman", .supplier = "pacman" },
        .{ .dependency = "libalpm", .supplier = "libalpm" },
        .{ .dependency = "libalpm.so=16-64", .supplier = "alpm-runtime", .provides = "libalpm.so=16-64" },
        .{ .dependency = "lib:libalpm.so=16-64", .supplier = "alpm-runtime", .provides = "lib:libalpm.so=16-64" },
    }) |requirement| {
        var fixture = try Fixture.init(.rlpm);
        defer fixture.deinit();
        const a = fixture.arena.allocator();
        try addRepository(&fixture);
        {
            const file = try fixture.temp.dir.createFile(t.io, "db/sync/testing.db", .{});
            defer file.close(t.io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(t.io, &buffer);
            var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
            const Package = struct {
                name: []const u8,
                dependency: []const u8 = "",
                provides: []const u8 = "",
            };
            for ([_]Package{
                .{ .name = "recipe", .dependency = "tool" },
                .{ .name = "tool", .dependency = requirement.dependency },
                .{ .name = requirement.supplier, .provides = requirement.provides },
            }) |package| {
                const filename = try std.fmt.allocPrint(a, "{s}-1-1-any.pkg.tar", .{package.name});
                const cache_path = try std.fs.path.join(a, &.{ "cache", filename });
                const payload_path = try std.fmt.allocPrint(a, "usr/share/{s}", .{package.name});
                {
                    const archive = try fixture.temp.dir.createFile(t.io, cache_path, .{});
                    defer archive.close(t.io);
                    var archive_buffer: [4096]u8 = undefined;
                    var archive_writer = archive.writer(t.io, &archive_buffer);
                    var archive_tar: std.tar.Writer = .{ .underlying_writer = &archive_writer.interface };
                    const dependency = if (package.dependency.len == 0) "" else try std.fmt.allocPrint(a, "depend = {s}\n", .{package.dependency});
                    const provides = if (package.provides.len == 0) "" else try std.fmt.allocPrint(a, "provides = {s}\n", .{package.provides});
                    const metadata = try std.fmt.allocPrint(a, "pkgname = {s}\npkgver = 1-1\narch = any\n{s}{s}", .{ package.name, dependency, provides });
                    try archive_tar.writeFileBytes(".PKGINFO", metadata, .{ .mode = 0o644 });
                    try archive_tar.writeFileBytes(payload_path, package.name, .{ .mode = 0o644 });
                    try archive_tar.finishPedantically();
                    try archive_writer.interface.flush();
                }
                const bytes = try fixture.temp.dir.readFileAlloc(t.io, cache_path, a, .limited(64 * 1024));
                var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                const checksum = std.fmt.bytesToHex(digest, .lower);
                const desc_path = try std.fmt.allocPrint(a, "{s}-1-1/desc", .{package.name});
                const desc = try std.fmt.allocPrint(
                    a,
                    "%NAME%\n{s}\n\n%VERSION%\n1-1\n\n%ARCH%\nany\n\n%FILENAME%\n{s}\n\n" ++
                        "%CSIZE%\n{d}\n\n%SHA256SUM%\n{s}\n\n%DEPENDS%\n{s}\n\n%PROVIDES%\n{s}\n\n",
                    .{ package.name, filename, bytes.len, checksum, package.dependency, package.provides },
                );
                try tar.writeFileBytes(desc_path, desc, .{ .mode = 0o644 });
            }
            try tar.finishPedantically();
            try writer.interface.flush();
        }
        const manager = try fixture.manager();
        defer manager.deinit();
        var targets = [_][:0]const u8{"recipe"};
        try manager.install_packages(&targets, .{ .nohooks = true, .noscriptlet = true });
        try t.expectEqual(pm.Manager.Backend.rlpm, manager.backend());
        try t.expect(try manager.is_dependency_satisfied_by_installed_packages(requirement.dependency));
        const installed = try manager.get_installed_packages();
        defer pm.Manager.OwnedPackage.deinitSlice(t.allocator, installed);
        try t.expectEqual(@as(usize, 3), installed.len);
        for ([_][]const u8{ "recipe", "tool", requirement.supplier }) |name| {
            const path = try std.fmt.allocPrint(a, "root/usr/share/{s}", .{name});
            const payload = try fixture.temp.dir.readFileAlloc(t.io, path, a, .limited(64));
            try t.expectEqualStrings(name, payload);
        }
        try t.expectError(error.FileNotFound, fixture.temp.dir.statFile(t.io, "db/db.lck", .{}));
    }
}

test "native backend archive install query reason and removal in private roots" {
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        const manager = try fixture.manager();
        defer manager.deinit();
        try t.expectEqual(backend, manager.backend());
        var archive = try manager.load_archive(fixture.archive);
        defer archive.deinit(t.allocator);
        try t.expectEqualStrings("backend-fixture", archive.name_value);
        try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
        var installed = (try manager.get_single_installed_package("backend-fixture")).?;
        defer installed.deinit(t.allocator);
        try t.expectEqualStrings("1-1", installed.version_value);
        try t.expect(try manager.is_dependency_satisfied_by_installed_packages("fixture-provider>=1"));
        try manager.update_package_reason("backend-fixture", .Dependency);
        try manager.refresh();
        var changed = (try manager.get_single_installed_package("backend-fixture")).?;
        defer changed.deinit(t.allocator);
        try t.expectEqual(pm.Manager.types.PackageReason.Dependency, changed.reason_value);
        const payload = try fixture.temp.dir.readFileAlloc(t.io, "root/usr/share/backend-fixture", t.allocator, .limited(64));
        defer t.allocator.free(payload);
        try t.expectEqualStrings("fixture\n", payload);
        var targets = [_][:0]const u8{"backend-fixture"};
        try manager.remove_packages_with_confirmation(&targets, .{ .nohooks = true, .noscriptlet = true }, true, .already_approved);
        try t.expect((try manager.get_single_installed_package("backend-fixture")) == null);
        try t.expectError(error.FileNotFound, fixture.temp.dir.statFile(t.io, "root/usr/share/backend-fixture", .{}));
    }
}

test "native backend missing backup members match libalpm and preserve unrelated files" {
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        {
            var file = try fixture.temp.dir.createFile(t.io, "fixture.pkg.tar", .{});
            defer file.close(t.io);
            var out: [4096]u8 = undefined;
            var writer = file.writer(t.io, &out);
            var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
            try tar.writeFileBytes(".PKGINFO", "pkgname = backend-fixture\npkgver = 1-1\narch = any\nbackup = etc/missing\nbackup = etc/present\n", .{ .mode = 0o644 });
            try tar.writeFileBytes("etc/present", "configuration", .{ .mode = 0o644 });
            try tar.finishPedantically();
            try writer.interface.flush();
        }
        try fixture.temp.dir.createDirPath(t.io, "root/etc");
        try fixture.temp.dir.writeFile(t.io, .{ .sub_path = "root/etc/missing", .data = "unowned configuration" });
        const manager = try fixture.manager();
        defer manager.deinit();
        // Reinstallation must also leave the unrelated file alone.
        for (0..2) |_| {
            try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
            const record = try fixture.temp.dir.readFileAlloc(t.io, "db/local/backend-fixture-1-1/files", t.allocator, .limited(4096));
            defer t.allocator.free(record);
            try t.expect(std.mem.indexOf(u8, record, "etc/missing\t(null)\n") != null);
            try t.expect(std.mem.indexOf(u8, record, "%FILES%\netc/present\n") != null);
        }
        var targets = [_][:0]const u8{"backend-fixture"};
        try manager.remove_packages_with_confirmation(&targets, .{ .nohooks = true, .noscriptlet = true }, true, .already_approved);
        const untouched = try fixture.temp.dir.readFileAlloc(t.io, "root/etc/missing", t.allocator, .limited(100));
        defer t.allocator.free(untouched);
        try t.expectEqualStrings("unowned configuration", untouched);
    }
}

test "native backend switching reopens compatible state and respects the shared lock" {
    if (!pm.Manager.libalpm_enabled) return;
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |first| {
        var fixture = try Fixture.init(first);
        defer fixture.deinit();
        {
            const manager = try fixture.manager();
            defer manager.deinit();
            try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
        }
        fixture.options.backend = if (first == .libalpm) .rlpm else .libalpm;
        const next = try fixture.manager();
        defer next.deinit();
        try t.expect(next.is_package_installed("backend-fixture"));
        try fixture.temp.dir.writeFile(t.io, .{ .sub_path = "db/db.lck", .data = "" });
        try t.expectError(error.TransInitFailed, next.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true }));
        try fixture.temp.dir.deleteFile(t.io, "db/db.lck");
        var targets = [_][:0]const u8{"backend-fixture"};
        try next.remove_packages_with_confirmation(&targets, .{ .nohooks = true, .noscriptlet = true }, true, .already_approved);
    }
}

fn addRepository(fixture: *Fixture) !void {
    const io = t.io;
    try fixture.temp.dir.createDirPath(io, "db/sync");
    try fixture.temp.dir.writeFile(io, .{ .sub_path = "pacman.conf", .data = "[options]\nArchitecture = auto\nSigLevel = Never\nLocalFileSigLevel = Never\n[testing]\nSigLevel = Never\nUsage = All\nServer = https://invalid.example/$repo/os/$arch\nCacheServer = https://cache.example/$repo/$arch\n" });
    var file = try fixture.temp.dir.createFile(io, "db/sync/testing.db", .{});
    defer file.close(io);
    var out: [4096]u8 = undefined;
    var writer = file.writer(io, &out);
    var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
    for ([_][2][]const u8{
        .{ "backend-fixture-2-1/desc", "%NAME%\nbackend-fixture\n\n%VERSION%\n2-1\n\n%DESC%\nUpgrade fixture\n\n%ARCH%\nany\n\n%GROUPS%\ntools\n\n%ISIZE%\n8\n\n" },
        .{ "provider-3-1/desc", "%NAME%\nprovider\n\n%VERSION%\n3-1\n\n%DESC%\nProvider\n\n%ARCH%\nany\n\n%PROVIDES%\nneeded=3\n\n%GROUPS%\ntools\n\n" },
        .{ "needed-2-1/desc", "%NAME%\nneeded\n\n%VERSION%\n2-1\n\n%DESC%\nLiteral\n\n%ARCH%\nany\n\n%GROUPS%\ntools\n\n" },
    }) |entry| try tar.writeFileBytes(entry[0], entry[1], .{ .mode = 0o644 });
    try tar.finishPedantically();
    try writer.interface.flush();
}

test "native backend repository queries preserve priority groups versions and owned records" {
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        try addRepository(&fixture);
        const manager = try fixture.manager();
        defer manager.deinit();
        try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
        const available = try manager.get_available_packages();
        defer pm.Manager.OwnedPackage.deinitSlice(t.allocator, available);
        try t.expectEqual(@as(usize, 3), available.len);
        const group = try manager.get_available_packages_from_group("tools");
        defer pm.Manager.OwnedPackage.deinitSlice(t.allocator, group);
        try t.expectEqual(@as(usize, 3), group.len);
        const literal = try manager.find_remote_satisfier_for_dependency_details("needed>=1");
        try t.expectEqualStrings("needed", literal.real_name);
        try t.expect(!literal.via_provides);
        const provider = try manager.find_remote_satisfier_for_dependency_details("needed>=3");
        try t.expectEqualStrings("provider", provider.real_name);
        try t.expect(provider.via_provides);
        const updates = try manager.get_updates_available();
        defer pm.Manager.OwnedPackageWithUpdate.deinitSlice(t.allocator, updates);
        try t.expectEqual(@as(usize, 1), updates.len);
        try t.expectEqualStrings("2-1", updates[0].new_package.version_value);
        try manager.refresh();
        try t.expectEqualStrings("1-1", updates[0].old_package.version_value);
        try t.expectEqualStrings("testing", updates[0].new_package.repository_value.?);
        try t.expectEqual(@as(usize, 1), manager.config.repositories.items[0].cache_servers.items.len);
    }
}

test "native backend needed no-op and declined plan preserve state and release the lock" {
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        const manager = try fixture.manager();
        defer manager.deinit();
        try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
        var context = pm.OperationContext.init(t.allocator, t.io);
        defer context.deinit();
        const Handler = struct {
            fn decline(_: ?*anyopaque, _: pm.operation.Question) pm.operation.QuestionResponse {
                return .declined;
            }
        };
        const Completion = struct {
            status: ?pm.operation.CompletionStatus = null,
            fn event(data: ?*anyopaque, value: pm.operation.Event) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                if (value == .completed) self.status = value.completed.status;
            }
        };
        var completion: Completion = .{};
        _ = try context.subscribe(.{ .function = Completion.event, .data = &completion });
        context.setQuestionHandler(.{ .function = Handler.decline });
        manager.setOperationContext(&context);
        defer manager.setOperationContext(null);
        try manager.install_local_packages(&.{fixture.archive}, .{ .needed = true, .nohooks = true, .noscriptlet = true });
        try t.expectEqual(pm.operation.CompletionStatus.success, completion.status.?);
        try t.expectError(error.NoPackageFound, manager.install_local_packages(&.{}, .{ .nohooks = true, .noscriptlet = true }));
        // Repository installs and removals ask for a prepared plan. A declined
        // removal keeps package state and frees the database lock.
        var targets = [_][:0]const u8{"backend-fixture"};
        try t.expectError(error.Cancelled, manager.remove_packages(&targets, .{ .nohooks = true, .noscriptlet = true }, true));
        try t.expectError(error.FileNotFound, fixture.temp.dir.statFile(t.io, "db/db.lck", .{}));
        manager.setOperationContext(null);
        try t.expect(manager.is_package_installed("backend-fixture"));
    }
}

test "native backend default changes apply only to subsequently initialized managers" {
    const previous = pm.Manager.defaultBackend();
    defer pm.Manager.setDefaultBackend(previous) catch unreachable;
    var fixture = try Fixture.init(.rlpm);
    defer fixture.deinit();
    const existing = try fixture.manager();
    defer existing.deinit();
    try pm.Manager.setDefaultBackend(pm.Manager.default_backend);
    try t.expectEqual(pm.Manager.Backend.rlpm, existing.backend());
    fixture.options.backend = null;
    const next = try fixture.manager();
    defer next.deinit();
    try t.expectEqual(pm.Manager.default_backend, next.backend());
}

test "native backend RLPM retains the owned worker executable across refresh" {
    var fixture = try Fixture.init(.rlpm);
    defer fixture.deinit();
    const manager = try fixture.manager();
    defer manager.deinit();
    try t.expectEqualStrings(fixture.options.worker_executable.?, manager.engine.?.rlpm.owner.options().worker_executable.?);
    try manager.refresh();
    try t.expectEqualStrings(fixture.options.worker_executable.?, manager.engine.?.rlpm.owner.options().worker_executable.?);
}

test "native backend RLPM preview copies metadata and rejects database aliases and writes" {
    var fixture = try Fixture.init(.rlpm);
    defer fixture.deinit();
    {
        const manager = try fixture.manager();
        defer manager.deinit();
        try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
    }
    const preview = try std.fs.path.join(fixture.arena.allocator(), &.{ fixture.options.database_path.?, "../preview" });
    // The libalpm frontend leaves this link in its reusable update-check cache.
    // Switching to RLPM must replace the link without traversing/deleting it.
    try fixture.temp.dir.createDirPath(t.io, "preview");
    try fixture.temp.dir.symLink(t.io, "../db/local", "preview/local", .{ .is_directory = true });
    fixture.options.temp_root_path = preview;
    {
        const manager = try fixture.manager();
        defer manager.deinit();
        try t.expect(manager.is_package_installed("backend-fixture"));
        try t.expectEqual(std.Io.File.Kind.directory, (try fixture.temp.dir.statFile(t.io, "preview/local", .{ .follow_symlinks = false })).kind);
        try t.expectError(error.CommitFailed, manager.install_local_packages(&.{fixture.archive}, .{}));
    }
    // Reopening also replaces an old snapshot safely.
    {
        const manager = try fixture.manager();
        defer manager.deinit();
        try t.expect(manager.is_package_installed("backend-fixture"));
    }
    try fixture.temp.dir.symLink(t.io, "db", "db-alias", .{ .is_directory = true });
    fixture.options.temp_root_path = try std.fs.path.join(fixture.arena.allocator(), &.{ fixture.options.database_path.?, "../db-alias" });
    try t.expectError(error.InvalidPreviewRoot, fixture.manager());
    // A link to a different directory is not the legacy libalpm cache entry.
    // Keep it and its target intact, and preserve the specific error.
    try fixture.temp.dir.createDirPath(t.io, "unrelated");
    try fixture.temp.dir.writeFile(t.io, .{ .sub_path = "unrelated/keep", .data = "keep" });
    try fixture.temp.dir.createDirPath(t.io, "other-preview");
    try fixture.temp.dir.symLink(t.io, "../unrelated", "other-preview/local", .{ .is_directory = true });
    fixture.options.temp_root_path = try std.fs.path.join(fixture.arena.allocator(), &.{ fixture.options.database_path.?, "../other-preview" });
    try t.expectError(error.InvalidPreviewRoot, fixture.manager());
    try t.expectEqual(std.Io.File.Kind.sym_link, (try fixture.temp.dir.statFile(t.io, "other-preview/local", .{ .follow_symlinks = false })).kind);
    try fixture.temp.dir.access(t.io, "unrelated/keep", .{});
    fixture.options.temp_root_path = null;
    const manager = try fixture.manager();
    defer manager.deinit();
    try t.expect(manager.is_package_installed("backend-fixture"));
}

test "native backend RLPM sync reports repository causes through both event interfaces" {
    var fixture = try Fixture.init(.rlpm);
    defer fixture.deinit();
    try fixture.temp.dir.writeFile(t.io, .{ .sub_path = "pacman.conf", .data = "[options]\nArchitecture = auto\nSigLevel = Never\n[unavailable]\nSigLevel = Never\n" });
    const manager = try fixture.manager();
    defer manager.deinit();
    var context = pm.OperationContext.init(t.allocator, t.io);
    defer context.deinit();
    const Capture = struct {
        cause: ?anyerror = null,
        repository_reported: bool = false,
        legacy_reported: bool = false,
        completion: ?pm.operation.CompletionStatus = null,
        fn event(data: ?*anyopaque, value: pm.operation.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (value) {
                .failure => |failure| {
                    self.cause = failure.err;
                    self.repository_reported = std.mem.indexOf(u8, failure.message, "unavailable") != null and
                        std.mem.indexOf(u8, failure.message, "NoServers") != null;
                },
                .completed => |completion| self.completion = completion.status,
                else => {},
            }
        }
        fn legacy(data: ?*anyopaque, value: pm.Manager.events.ErrorArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.legacy_reported = std.mem.indexOf(u8, value.message, "unavailable") != null and
                std.mem.indexOf(u8, value.message, "NoServers") != null;
        }
    };
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
    _ = try manager.dispatcher.addErrorHandler(.{ .function = Capture.legacy, .data = &capture });
    manager.setOperationContext(&context);
    defer manager.setOperationContext(null);
    try t.expectError(error.SyncDbFailed, manager.sync_for_update_check(true));
    try t.expectEqual(error.NoServers, capture.cause.?);
    try t.expect(capture.repository_reported and capture.legacy_reported);
    try t.expectEqual(pm.operation.CompletionStatus.failed, capture.completion.?);
    try t.expectError(error.FileNotFound, fixture.temp.dir.statFile(t.io, "db/db.lck", .{}));
}

test "native backend configuration maps extended options and rejects invalid parallelism" {
    const text = "[options]\nArchitecture = auto x86_64_v3\nCacheDir = /cache/first /cache/second\nCacheDir = /cache/third\nAssumeInstalled = virtual=2\nParallelDownloads = 7\nDownloadUser = nobody\nDisableDownloadTimeout\nDisableSandboxFilesystem\nDisableSandboxSyscalls\nDisableSandboxNetwork\nNoUpgrade = etc/demo\nNoExtract = usr/share/skip/*\n[testing]\nUsage = Search Install\nCacheServer = https://cache.example/$repo/$arch\nServer = https://mirror.example/$repo/$arch\n";
    var config = try pm.Manager.configuration.Configuration.parse_string(t.allocator, t.io, text);
    defer config.deinitialize();
    try t.expectEqual(@as(usize, 3), config.cache_directories.items.len);
    try t.expectEqual(@as(usize, 2), config.architectures.items.len);
    try t.expectEqual(@as(?u8, 7), config.parallel_downloads);
    try t.expectEqualStrings("virtual=2", config.assume_installed.items[0]);
    try t.expectEqualStrings("nobody", config.sandbox_user.?);
    try t.expect(config.disable_download_timeout and config.disable_sandbox_filesystem and config.disable_sandbox_syscalls and config.disable_sandbox_network);
    try t.expectEqualStrings("etc/demo", config.no_upgrade.items[0]);
    try t.expectEqualStrings("usr/share/skip/*", config.no_extract.items[0]);
    try t.expectEqual(@as(u32, 6), config.repositories.items[0].usage);
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        for ([_][]const u8{ "0", "256", "bad" }) |invalid| {
            const contents = try std.fmt.allocPrint(t.allocator, "[options]\nParallelDownloads = {s}\n", .{invalid});
            defer t.allocator.free(contents);
            try fixture.temp.dir.writeFile(t.io, .{ .sub_path = "pacman.conf", .data = contents });
            try t.expectError(error.ConfigParseFailed, fixture.manager());
        }
    }
}

test "native backend cancelled operations fail without switching or writing a lock" {
    for ([_]pm.Manager.Backend{ .libalpm, .rlpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        const manager = try fixture.manager();
        defer manager.deinit();
        var context = pm.OperationContext.init(t.allocator, t.io);
        defer context.deinit();
        manager.setOperationContext(&context);
        defer manager.setOperationContext(null);
        context.cancel();
        try t.expectError(error.Cancelled, manager.install_local_packages(&.{fixture.archive}, .{}));
        try t.expectEqual(backend, manager.backend());
        try t.expectError(error.FileNotFound, fixture.temp.dir.statFile(t.io, "db/db.lck", .{}));
    }
}

test "native backend auto architecture and default hook paths survive refresh" {
    var expected: ?[][:0]const u8 = null;
    defer if (expected) |names| {
        for (names) |name| t.allocator.free(name);
        t.allocator.free(names);
    };
    for ([_]pm.Manager.Backend{ .rlpm, .libalpm }) |backend| {
        if (!backend.available()) continue;
        var fixture = try Fixture.init(backend);
        defer fixture.deinit();
        fixture.options.root_hooks_only = false;
        const manager = try fixture.manager();
        defer manager.deinit();
        try manager.refresh();
        const names = try manager.get_allowed_architecture();
        if (expected) |prior| {
            defer {
                for (names) |name| t.allocator.free(name);
                t.allocator.free(names);
            }
            try t.expectEqual(prior.len, names.len);
            for (prior, names) |left, right| try t.expectEqualStrings(left, right);
        } else expected = names;
        if (backend == .rlpm) {
            const hooks = manager.engine.?.rlpm.owner.configuration.hook_directories.?;
            const system = try std.fs.path.join(fixture.arena.allocator(), &.{ fixture.options.root_directory.?, "usr/share/libalpm/hooks" });
            try t.expectEqualStrings(system, std.mem.trimEnd(u8, hooks[0], "/"));
            try t.expect(hooks.len >= 2);
        }
    }
}

test "native backend forwards original transaction failures to bootstrap handlers without duplicating operation errors" {
    for ([_]bool{ false, true }) |with_context| {
        var fixture = try Fixture.init(.rlpm);
        defer fixture.deinit();
        {
            var file = try fixture.temp.dir.createFile(t.io, "fixture.pkg.tar", .{});
            defer file.close(t.io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writer(t.io, &buffer);
            var tar: std.tar.Writer = .{ .underlying_writer = &writer.interface };
            try tar.writeFileBytes(".PKGINFO", "pkgname = bootstrap-fixture\npkgver = 1-1\narch = any\n", .{ .mode = 0o644 });
            try tar.writeFileBytes(".MTREE", "#mtree\n./missing type=file\n", .{ .mode = 0o644 });
            try tar.writeFileBytes("present", "payload", .{ .mode = 0o644 });
            try tar.finishPedantically();
            try writer.interface.flush();
        }
        var context = pm.OperationContext.init(t.allocator, t.io);
        defer context.deinit();
        if (with_context) fixture.options.operation_context = &context;
        const manager = try fixture.manager();
        defer manager.deinit();
        const Capture = struct {
            messages: usize = 0,
            original: bool = false,
            package: bool = false,
            path: bool = false,
            failures: usize = 0,
            fn errorMessage(data: ?*anyopaque, value: pm.Manager.events.ErrorArgs) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                self.messages += 1;
                self.original = std.mem.indexOf(u8, value.message, "ArchiveInventoryMismatch") != null;
                self.package = std.mem.indexOf(u8, value.message, "bootstrap-fixture") != null;
                self.path = std.mem.indexOf(u8, value.message, "Path: missing") != null;
            }
            fn event(data: ?*anyopaque, value: pm.OperationEvent) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                if (value == .failure) self.failures += 1;
            }
        };
        var capture: Capture = .{};
        _ = try manager.dispatcher.addErrorHandler(.{ .function = Capture.errorMessage, .data = &capture });
        _ = try context.subscribe(.{ .function = Capture.event, .data = &capture });
        try t.expectError(error.CommitFailed, manager.install_local_packages(&.{fixture.archive}, .{}));
        try t.expectEqual(@as(usize, 1), capture.messages);
        try t.expect(capture.original and capture.package and capture.path);
        try t.expectEqual(@as(usize, if (with_context) 1 else 0), capture.failures);
    }
}

test "native backend output observers receive preparation and transaction progress without changing standalone behavior" {
    var fixture = try Fixture.init(.rlpm);
    defer fixture.deinit();
    const manager = try fixture.manager();
    defer manager.deinit();
    const Capture = struct {
        checking_databases: bool = false,
        checking_archives: bool = false,
        internal_status_seen: bool = false,
        package_started: bool = false,
        progress: bool = false,
        completions: usize = 0,
        events: usize = 0,
        fn event(data: ?*anyopaque, value: pm.OperationEvent) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.events += 1;
            switch (value) {
                .status => |status| {
                    if (std.mem.startsWith(u8, status.message, "Checking package databases")) self.checking_databases = true;
                    if (std.mem.eql(u8, status.code orelse "", "rlpm.lifecycle")) self.internal_status_seen = true;
                    if (std.mem.startsWith(u8, status.message, "Checking package archive (1/1): backend-fixture")) self.checking_archives = true;
                    if (status.package_name) |name| {
                        if (std.mem.eql(u8, name, "backend-fixture")) self.package_started = self.checking_archives;
                    }
                },
                .progress => |progress| {
                    if (progress.update.stage) |stage| if (std.mem.eql(u8, stage, "transaction")) {
                        self.progress = true;
                    };
                },
                .completed => self.completions += 1,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    const handler = try manager.dispatcher.addOperationHandler(.{ .function = Capture.event, .data = &capture });
    try manager.install_local_packages(&.{fixture.archive}, .{ .nohooks = true, .noscriptlet = true });
    try t.expect(capture.checking_databases and !capture.internal_status_seen);
    try t.expect(capture.checking_archives and capture.package_started and capture.progress);
    try t.expectEqual(@as(usize, 1), capture.completions);
    try manager.sync(false);
    try t.expectEqual(@as(usize, 2), capture.completions);
    manager.dispatcher.removeOperationHandler(handler);
    const previous_events = capture.events;
    try manager.install_local_packages(&.{fixture.archive}, .{ .needed = true, .nohooks = true, .noscriptlet = true });
    try t.expectEqual(previous_events, capture.events);
}
