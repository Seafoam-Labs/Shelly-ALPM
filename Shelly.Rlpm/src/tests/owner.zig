const std = @import("std");
const rlpm = @import("Shelly_Rlpm");

const io = std.testing.io;
const allocator = std.testing.allocator;

const Fixture = struct {
    temporary: std.testing.TmpDir,
    root: [:0]const u8,
    db: [:0]const u8,

    fn init(populated: bool) !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        try temporary.dir.createDirPath(io, "root");
        try temporary.dir.createDirPath(io, "db");
        const root = try temporary.dir.realPathFileAlloc(io, "root", allocator);
        errdefer allocator.free(root);
        const db = try temporary.dir.realPathFileAlloc(io, "db", allocator);
        errdefer allocator.free(db);
        if (populated) {
            for ([_][]const u8{ "zeta", "alpha", "beta" }) |name| {
                const dir = try std.fmt.allocPrint(allocator, "db/local/{s}-1.0-1", .{name});
                defer allocator.free(dir);
                try temporary.dir.createDirPath(io, dir);
                const path = try std.fmt.allocPrint(allocator, "{s}/desc", .{dir});
                defer allocator.free(path);
                const contents = try std.fmt.allocPrint(
                    allocator,
                    "%NAME%\n{s}\n\n%VERSION%\n1.0-1\n\n%GROUPS%\ncommon\n\n%INSTALLED_DB%\ncachyos\n\n%DEPENDS%\nruntime>=2\n",
                    .{name},
                );
                defer allocator.free(contents);
                try temporary.dir.writeFile(io, .{ .sub_path = path, .data = contents });
            }
            try temporary.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
        }
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

    fn configuration(self: Fixture) rlpm.OwnerConfiguration {
        return .{ .root = self.root, .database_path = self.db };
    }
};

const repositories = [_]rlpm.DatabaseConfiguration{
    .{
        .database_name = "core",
        .servers = &.{
            "https://first.invalid/core/",
            "https://second.invalid/core//",
        },
        .cache_servers = &.{"https://cache.invalid/"},
    },
    .{
        .database_name = "cachyos",
        .usage = .{ .search = false },
        .signature_policy = .{
            .package = .required,
            .database = .optional,
        },
    },
};

fn completeConfiguration(fixture: Fixture) rlpm.OwnerConfiguration {
    var config = fixture.configuration();
    config.cache_directories = &.{ "/cache/one", "relative-cache" };
    config.hook_directories = &.{ "/hooks/one", "relative-hooks" };
    config.gpg_directory = "relative-keys";
    config.log_file = "/logs/packages.log";
    config.use_syslog = true;
    config.architectures = &.{ "x86_64", "x86_64_v3" };
    config.ignore_packages = &.{ "kernel", "editor*" };
    config.ignore_groups = &.{"development"};
    config.assume_installed = &.{
        .{
            .name = "runtime",
            .constraint = .{ .equal = "2:1.0-1" },
            .description = "provided by the environment",
        },
    };
    config.no_upgrade = &.{"etc/config"};
    config.no_extract = &.{ "usr/share/docs/*", "!usr/share/docs/keep" };
    config.overwrite_files = &.{"usr/bin/*"};
    config.database_extension = ".files";
    config.check_space = true;
    config.default_signature_policy = .{
        .package = .required,
        .database = .optional,
        .package_trust = .{ .allow_marginal = true },
    };
    config.local_file_signature_policy = null;
    config.remote_file_signature_policy = .{ .package = .disabled, .database = .disabled };
    config.disable_download_timeout = true;
    config.parallel_downloads = 7;
    config.sandbox_user = "unresolved-sandbox-user";
    config.worker_executable = "/usr/bin/shelly";
    config.sandbox.setDisabled(true);
    config.sandbox.disable_network = false;
    return config;
}

test "owner paths use canonical independent root and database directories" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    try fixture.temporary.dir.symLink(io, "root", "root-link", .{ .is_directory = true });
    const link = try fixture.temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(link);
    const root_link = try std.fmt.allocPrint(allocator, "{s}/root-link/./", .{link});
    defer allocator.free(root_link);
    var config = fixture.configuration();
    config.root = root_link;
    var owner = try rlpm.Owner.init(io, allocator, config, &repositories);
    defer owner.deinit() catch unreachable;
    const expected_root = try std.fmt.allocPrint(allocator, "{s}/", .{fixture.root});
    defer allocator.free(expected_root);
    try std.testing.expectEqualStrings(expected_root, owner.options().root);
    const local = try owner.database(owner.localDatabase().?);
    const expected_local = try std.fmt.allocPrint(allocator, "{s}/local/", .{fixture.db});
    defer allocator.free(expected_local);
    try std.testing.expectEqualStrings(expected_local, local.path);
    try std.testing.expectEqual(.exists, local.status.presence);
    const expected_sync = try std.fmt.allocPrint(allocator, "{s}/sync/core.db", .{fixture.db});
    defer allocator.free(expected_sync);
    try std.testing.expectEqualStrings(expected_sync, owner.syncDatabases()[0].path);
    const expected_hook = try std.fmt.allocPrint(allocator, "{s}/usr/share/libalpm/hooks/", .{fixture.root});
    defer allocator.free(expected_hook);
    try std.testing.expectEqualStrings(expected_hook, owner.options().hook_directories.?[0]);
    _ = try fixture.temporary.dir.statFile(io, "db/local/ALPM_DB_VERSION", .{});
    try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.statFile(io, "db/sync", .{}));
    try std.testing.expectError(error.FileNotFound, owner.loadDatabase(io, owner.findDatabase("core").?));
    try std.testing.expectEqual(.io, owner.diagnostic().?.category);
    var message: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&message);
    try owner.diagnostic().?.format(&writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "load_database: FileNotFound"));
    try std.testing.expectError(error.DatabaseNotLoaded, owner.packageIds(owner.findDatabase("core").?));
}

test "owner owns caller configuration, relation versions, and ordered server lists" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var owner = blk: {
        var inputs = std.heap.ArenaAllocator.init(allocator);
        defer inputs.deinit();
        const input = inputs.allocator();
        var config = completeConfiguration(fixture);
        const copied = try config.copy(input, io);
        config = copied;
        var repos = repositories;
        repos[0].database_name = try input.dupe(u8, "core");
        const servers = try input.alloc([]const u8, 1);
        servers[0] = try input.dupe(u8, "https://owned.invalid/");
        repos[0].servers = servers;
        break :blk try rlpm.Owner.init(io, allocator, config, &repos);
    };
    defer owner.deinit() catch unreachable;
    const config = owner.options();
    try std.testing.expectEqualStrings("relative-cache/", config.cache_directories[1]);
    try std.testing.expectEqualStrings("relative-hooks/", config.hook_directories.?[1]);
    try std.testing.expectEqualStrings("relative-keys/", config.gpg_directory.?);
    try std.testing.expectEqualStrings("/logs/packages.log", config.log_file.?);
    try std.testing.expect(config.use_syslog and config.check_space and config.disable_download_timeout);
    try std.testing.expectEqual(7, config.parallel_downloads);
    try std.testing.expectEqualStrings("x86_64_v3", config.architectures[1]);
    try std.testing.expectEqualStrings("editor*", config.ignore_packages[1]);
    try std.testing.expectEqualStrings("development", config.ignore_groups[0]);
    try std.testing.expectEqualStrings("2:1.0-1", config.assume_installed[0].constraint.equal);
    try std.testing.expectEqualStrings("etc/config", config.no_upgrade[0]);
    try std.testing.expectEqualStrings("!usr/share/docs/keep", config.no_extract[1]);
    try std.testing.expectEqualStrings("usr/bin/*", config.overwrite_files[0]);
    try std.testing.expectEqualStrings("unresolved-sandbox-user", config.sandbox_user.?);
    try std.testing.expectEqualStrings("/usr/bin/shelly", config.worker_executable.?);
    try std.testing.expect(
        config.sandbox.disable_filesystem and config.sandbox.disable_syscalls and
            !config.sandbox.disable_network,
    );
    try std.testing.expect(config.effectiveLocalSignaturePolicy().package_trust.allow_marginal);
    try std.testing.expectEqual(.disabled, config.effectiveRemoteSignaturePolicy().package);
    const core = try owner.database(owner.findDatabase("core").?);
    try std.testing.expectEqualStrings("https://owned.invalid", core.servers.items[0]);
    try std.testing.expect(core.signature_policy.package_trust.allow_marginal);
    try std.testing.expect(std.mem.endsWith(u8, core.path, "/sync/core.files"));
    const local = try owner.database(owner.localDatabase().?);
    try std.testing.expectEqual(.disabled, local.signature_policy.database);
    try std.testing.expectEqual(3, (try owner.packageIds(owner.localDatabase().?)).len);
}

test "registration validates names and preserves stable identities across growth and removal" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &repositories);
    defer owner.deinit() catch unreachable;
    const core = owner.findDatabase("core").?;
    try std.testing.expectError(
        error.DuplicateDatabase,
        owner.registerDatabase(.{ .database_name = "core" }),
    );
    try std.testing.expectError(
        error.ReservedDatabaseName,
        owner.registerDatabase(
            .{ .database_name = "local" },
        ),
    );
    for ([_][]const u8{ "", "path/repo", "bad\x00name" }) |name| {
        try std.testing.expectError(
            error.InvalidDatabaseName,
            owner.registerDatabase(
                .{ .database_name = name },
            ),
        );
    }
    try std.testing.expectEqual(2, owner.syncDatabases().len);
    for (0..20) |i| {
        const name = try std.fmt.allocPrint(allocator, "repository-{d}", .{i});
        defer allocator.free(name);
        _ = try owner.registerDatabase(.{ .database_name = name });
    }
    try std.testing.expectEqualStrings("core", (try owner.database(core)).name);
    try owner.unregisterDatabase(core);
    const replacement = try owner.registerDatabase(.{ .database_name = "core" });
    try std.testing.expect(!core.eql(replacement));
    try std.testing.expectEqualStrings("cachyos", owner.syncDatabases()[0].name);
    try std.testing.expectEqualStrings("core", owner.syncDatabases()[owner.syncDatabases().len - 1].name);
    try std.testing.expectError(error.StaleDatabaseReference, owner.unregisterDatabase(core));
    try std.testing.expectEqual(.stale_reference, owner.diagnostic().?.category);
    var other = try rlpm.Owner.init(io, allocator, fixture.configuration(), &repositories);
    defer other.deinit() catch unreachable;
    try std.testing.expectError(error.ForeignOwner, other.database(replacement));
    try std.testing.expectError(error.ForeignOwner, other.unregisterDatabase(replacement));
    const local = owner.localDatabase().?;
    try owner.unregisterDatabase(local);
    try std.testing.expect(owner.localDatabase() == null);
    try std.testing.expectError(error.StaleDatabaseReference, owner.database(local));
}

test "local queries retain repository provenance and reject invalidated package references" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &.{});
    defer owner.deinit() catch unreachable;
    const local = owner.localDatabase().?;
    const alpha = (try owner.findPackage(local, "alpha")).?;
    try std.testing.expectEqualStrings("local", (try owner.package(alpha)).database_name);
    try std.testing.expectEqualStrings(
        "cachyos",
        (try owner.packageMetadata(io, alpha, .{})).installed_database.?,
    );
    try std.testing.expect(try owner.findPackage(local, "absent") == null);
    try std.testing.expect(try owner.findGroup(io, local, "absent") == null);
    const expected = [_][]const u8{ "alpha", "beta", "zeta" };
    for (try owner.packageIds(local), expected) |id, name| {
        try std.testing.expectEqualStrings(
            name,
            (try owner.package(try owner.packageReference(local, id))).name,
        );
    }
    const group = (try owner.findGroup(io, local, "common")).?;
    for (group.packages.items, expected) |id, name| {
        try std.testing.expectEqualStrings(
            name,
            (try owner.package(try owner.packageReference(local, id))).name,
        );
    }
    try std.testing.expectError(
        error.StalePackageReference,
        owner.packageReference(local, @enumFromInt(999)),
    );
    try owner.invalidateDatabase(local);
    try std.testing.expectError(error.StalePackageReference, owner.package(alpha));
    try std.testing.expectError(error.DatabaseNotLoaded, owner.findPackage(local, "alpha"));
    try owner.loadDatabase(io, local);
    try std.testing.expectError(error.StalePackageReference, owner.package(alpha));
    try std.testing.expectEqualStrings(
        "alpha",
        (try owner.package((try owner.findPackage(local, "alpha")).?)).name,
    );
    try std.testing.expectError(error.DatabaseAlreadyLoaded, owner.loadDatabase(io, local));
}

test "option replacement updates paths and inheritance without altering local metadata" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &repositories);
    defer owner.deinit() catch unreachable;
    const local = owner.localDatabase().?;
    const alpha = (try owner.findPackage(local, "alpha")).?;
    const core = owner.findDatabase("core").?;
    const generation = (try owner.database(core)).generation;
    var update = owner.options();
    update.database_extension = ".files";
    update.default_signature_policy = .{ .package = .optional, .database = .required };
    update.local_file_signature_policy = null;
    try owner.setOptions(io, update);
    try std.testing.expectEqualStrings("alpha", (try owner.package(alpha)).name);
    try std.testing.expect((try owner.database(core)).generation > generation);
    try std.testing.expect(std.mem.endsWith(u8, (try owner.database(core)).path, "/core.files"));
    try std.testing.expectEqual(.optional, (try owner.database(core)).signature_policy.package);
    try std.testing.expectEqual(
        .required,
        (try owner.database(owner.findDatabase("cachyos").?)).signature_policy.package,
    );
    try std.testing.expectEqual(.optional, owner.options().effectiveLocalSignaturePolicy().package);
    // Recopying an already stored URL must not strip another slash.
    try std.testing.expectEqualStrings(
        "https://second.invalid/core/",
        (try owner.database(core)).servers.items[1],
    );
    update = owner.options();
    update.root = fixture.db;
    try std.testing.expectError(error.ImmutablePath, owner.setOptions(io, update));
    update = owner.options();
    update.parallel_downloads = 0;
    try std.testing.expectError(error.InvalidOption, owner.setOptions(io, update));
    update = owner.options();
    update.database_extension = "/../escape";
    try std.testing.expectError(error.InvalidOption, owner.setOptions(io, update));
    try std.testing.expectEqualStrings(".files", owner.options().database_extension);
}

test "ordered option lists support replacement append and first-match removal" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &.{});
    defer owner.deinit() catch unreachable;
    inline for (comptime std.meta.tags(rlpm.OwnerConfiguration.StringList)) |field| {
        try owner.setList(io, field, &.{ "first", "second", "first" });
        try owner.addListValue(io, field, "last");
        try std.testing.expectEqual(4, owner.options().list(field).len);
        try std.testing.expect(try owner.removeListValue(io, field, "first"));
        const directory = field == .cache_directories or field == .hook_directories;
        try std.testing.expectEqualStrings(
            if (directory) "second/" else "second",
            owner.options().list(field)[0],
        );
        try std.testing.expectEqualStrings(
            if (directory) "first/" else "first",
            owner.options().list(field)[1],
        );
        try std.testing.expect(!try owner.removeListValue(io, field, "absent"));
        try owner.setList(io, field, &.{});
        try std.testing.expectEqual(0, owner.options().list(field).len);
    }
}

test "invalid initialization and partial registration release everything" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var config = fixture.configuration();
    config.root = "";
    try std.testing.expectError(error.InvalidPath, rlpm.Owner.init(io, allocator, config, &.{}));
    config = fixture.configuration();
    config.database_path = "/rlpm-test-does-not-exist";
    try std.testing.expectError(error.FileNotFound, rlpm.Owner.init(io, allocator, config, &.{}));
    for ([_][]const u8{ "", "shelly", "./shelly", "/usr/bin/shelly\x00suffix" }) |path| {
        config = fixture.configuration();
        config.worker_executable = path;
        try std.testing.expectError(error.InvalidOption, rlpm.Owner.init(io, allocator, config, &.{}));
    }
    config = fixture.configuration();
    try std.testing.expectError(
        error.DuplicateDatabase,
        rlpm.Owner.init(
            io,
            allocator,
            config,
            &.{ repositories[0], repositories[0] },
        ),
    );
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db/local", .data = "not a directory" });
    try std.testing.expectError(error.NotDir, rlpm.Owner.init(io, allocator, config, &repositories));
}

const Capture = struct {
    owner: *rlpm.Owner,
    called: usize = 0,
    registration_error: ?anyerror = null,
    release_error: ?anyerror = null,
    cancel: bool = false,
    invalid_answer: bool = false,
    change_tag: bool = false,

    fn onEvent(context: ?*anyopaque, event: rlpm.Callbacks.Event) void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        std.debug.assert(event == .database_missing);
        self.called += 1;
        _ = self.owner.registerDatabase(.{ .database_name = "reentrant" }) catch |err| blk: {
            self.registration_error = err;
            break :blk self.owner.localDatabase().?;
        };
        self.owner.deinit() catch |err| {
            self.release_error = err;
        };
        if (self.cancel) self.owner.requestCancellation();
    }

    fn onQuestion(context: ?*anyopaque, question: *rlpm.Callbacks.Question) void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        self.called += 1;
        if (self.change_tag) {
            question.* = .{ .corrupted = .{ .path = "changed", .reason = error.TestFailure } };
        } else switch (question.*) {
            .install_ignored => |*payload| payload.install = true,
            .select_provider => |*payload| payload.selected = if (self.invalid_answer) 999 else 1,
            else => {},
        }
        if (self.cancel) self.owner.requestCancellation();
    }
};

test "callbacks carry contexts, reject reentry, and propagate cancellation" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &.{});
    defer owner.deinit() catch unreachable;
    var capture: Capture = .{ .owner = &owner };
    try owner.setCallbacks(
        .{
            .event = Capture.onEvent,
            .event_context = &capture,
            .question = Capture.onQuestion,
            .question_context = &capture,
        },
    );
    try owner.emit(.{ .database_missing = owner.localDatabase().? });
    try std.testing.expectEqual(error.CallbackReentry, capture.registration_error.?);
    try std.testing.expectEqual(error.CallbackReentry, capture.release_error.?);
    try std.testing.expect(owner.findDatabase("reentrant") == null);
    const alpha = (try owner.findPackage(owner.localDatabase().?, "alpha")).?;
    var question: rlpm.Callbacks.Question = .{ .install_ignored = .{ .package = alpha } };
    try owner.ask(&question);
    try std.testing.expect(question.install_ignored.install);
    capture.cancel = true;
    question = .{ .install_ignored = .{ .package = alpha } };
    try std.testing.expectError(error.Cancelled, owner.ask(&question));
    try std.testing.expect(!question.install_ignored.install);
    try std.testing.expectEqual(.cancelled, owner.diagnostic().?.category);
    try std.testing.expectError(error.Cancelled, owner.checkCancelled());
    try owner.resetCancellation();
    try owner.checkCancelled();
    capture.cancel = false;
    try owner.setCallbacks(.{});
    question = .{ .install_ignored = .{ .package = alpha } };
    try owner.ask(&question);
    try std.testing.expect(!question.install_ignored.install);
}

test "provider answers are bounded and callbacks cannot replace the question tag" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &.{});
    defer owner.deinit() catch unreachable;
    const local = owner.localDatabase().?;
    const candidates = [_]rlpm.PackageRef{
        (try owner.findPackage(local, "alpha")).?,
        (try owner.findPackage(local, "beta")).?,
    };
    var capture: Capture = .{ .owner = &owner };
    try owner.setCallbacks(.{ .question = Capture.onQuestion, .question_context = &capture });
    var question: rlpm.Callbacks.Question = .{
        .select_provider = .{
            .dependency = .{ .name = "runtime" },
            .candidates = &candidates,
        },
    };
    try owner.ask(&question);
    try std.testing.expectEqual(1, question.select_provider.selected);
    capture.invalid_answer = true;
    try std.testing.expectError(error.InvalidAnswer, owner.ask(&question));
    try std.testing.expectEqual(1, question.select_provider.selected);
    capture.change_tag = true;
    try std.testing.expectError(error.InvalidAnswer, owner.ask(&question));
    try std.testing.expect(question == .select_provider);
}

fn allocationLifecycle(failing: std.mem.Allocator, fixture: Fixture) !void {
    var owner = try rlpm.Owner.init(io, failing, completeConfiguration(fixture), &repositories);
    defer owner.deinit() catch unreachable;
    _ = try owner.registerDatabase(.{ .database_name = "third", .servers = &.{"https://third.invalid/"} });
    var config = owner.options();
    config.database_extension = ".db";
    owner.setOptions(io, config) catch |err| {
        try std.testing.expectEqualStrings(".files", owner.options().database_extension);
        try std.testing.expectEqual(3, owner.syncDatabases().len);
        try std.testing.expectEqual(3, (try owner.packageIds(owner.localDatabase().?)).len);
        return err;
    };
    try owner.addListValue(io, .cache_directories, "another-cache");
    _ = try owner.removeListValue(io, .cache_directories, "another-cache");
    const local = owner.localDatabase().?;
    try owner.invalidateDatabase(local);
    try owner.loadDatabase(io, local);
    try owner.unregisterSyncDatabases();
}

test "owner lifecycle propagates every allocation failure and releases all owned storage" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(allocator, allocationLifecycle, .{fixture});
}

test "failed option replacement preserves old options and database identities" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var owner = try rlpm.Owner.init(io, failing.allocator(), fixture.configuration(), &repositories);
    defer owner.deinit() catch unreachable;
    const reference = owner.findDatabase("core").?;
    const before = (try owner.database(reference)).generation;
    var config = owner.options();
    config.database_extension = ".files";
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.setOptions(io, config));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqualStrings(".db", owner.options().database_extension);
    try std.testing.expectEqual(before, (try owner.database(reference)).generation);
    try std.testing.expectEqual(3, (try owner.packageIds(owner.localDatabase().?)).len);
    try owner.setOptions(io, config);
}

test "owner defaults and registration match independently recorded libalpm results" {
    const fixture_json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        @embedFile("fixtures/owner-reference.json"),
        .{},
    );
    defer fixture_json.deinit();
    const manifest = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        @embedFile("reference/manifest.json"),
        .{},
    );
    defer manifest.deinit();
    const reference = fixture_json.value.object;
    try std.testing.expectEqualStrings(
        manifest.value.object.get("library").?.object.get("sha256").?.string,
        reference.get("library_sha256").?.string,
    );
    const defaults = reference.get("defaults").?.object;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var owner = try rlpm.Owner.init(io, allocator, fixture.configuration(), &repositories);
    defer owner.deinit() catch unreachable;
    const options = owner.options();
    try expectReferencePath(options.root, defaults.get("root").?.string, fixture);
    try expectReferencePath(options.database_path, defaults.get("dbpath").?.string, fixture);
    try expectReferencePath(owner.lock_file, defaults.get("lockfile").?.string, fixture);
    try std.testing.expectEqualStrings(defaults.get("dbext").?.string, options.database_extension);
    try std.testing.expectEqual(
        @as(u32, @intCast(defaults.get("parallel_downloads").?.integer)),
        options.parallel_downloads,
    );
    inline for (.{
        .{ "checkspace", "check_space" }, .{ "usesyslog", "use_syslog" },
        .{
            "disable_dl_timeout",
            "disable_download_timeout",
        },
    }) |pair| {
        try std.testing.expectEqual(defaults.get(pair[0]).?.integer != 0, @field(options, pair[1]));
    }
    inline for (.{
        .{ "gpgdir", "gpg_directory" },
        .{ "logfile", "log_file" },
        .{ "sandboxuser", "sandbox_user" },
    }) |pair| {
        try std.testing.expect(defaults.get(pair[0]).? == .null);
        try std.testing.expect(@field(options, pair[1]) == null);
    }
    inline for (.{
        .{ "cachedirs", "cache_directories" },     .{ "architectures", "architectures" },
        .{ "ignorepkgs", "ignore_packages" },      .{ "ignoregroups", "ignore_groups" },
        .{ "noupgrades", "no_upgrade" },           .{ "noextracts", "no_extract" },
        .{ "overwrite_files", "overwrite_files" },
    }) |pair| {
        try std.testing.expectEqual(defaults.get(pair[0]).?.array.items.len, @field(options, pair[1]).len);
    }
    const hooks = defaults.get("hookdirs").?.array.items;
    try std.testing.expectEqual(hooks.len, options.hook_directories.?.len);
    for (hooks, options.hook_directories.?) |expected, actual|
        try expectReferencePath(
            actual,
            expected.string,
            fixture,
        );
    inline for (.{ "default_siglevel", "local_file_siglevel", "remote_file_siglevel" }) |key|
        try std.testing.expectEqual(
            0,
            defaults.get(key).?.integer,
        );
    for ([_]rlpm.SignaturePolicy{
        options.default_signature_policy,
        options.effectiveLocalSignaturePolicy(),
        options.effectiveRemoteSignaturePolicy(),
    }) |policy| {
        try std.testing.expectEqual(.disabled, policy.package);
        try std.testing.expectEqual(.disabled, policy.database);
    }
    const order = reference.get("repository_order").?.array.items;
    try std.testing.expectEqual(order.len, owner.syncDatabases().len);
    for (order, owner.syncDatabases()) |expected, actual|
        try std.testing.expectEqualStrings(
            expected.string,
            actual.name,
        );
    for (reference.get("rejected_registration_names").?.array.items) |name| {
        if (owner.registerDatabase(.{ .database_name = name.string })) |_| {
            return error.UnexpectedRegistrationSuccess;
        } else |err| switch (err) {
            error.DuplicateDatabase, error.ReservedDatabaseName, error.InvalidDatabaseName => {},
            else => return err,
        }
    }
    const expected_servers = reference.get("servers_after_add").?.array.items;
    const actual_servers = (try owner.database(owner.findDatabase("core").?)).servers.items;
    try std.testing.expectEqual(expected_servers.len, actual_servers.len);
    for (expected_servers, actual_servers) |expected, actual|
        try std.testing.expectEqualStrings(
            expected.string,
            actual,
        );
    var sandbox: rlpm.OwnerConfiguration.Sandbox = .{};
    for (reference.get("sandbox").?.array.items) |step| {
        const state = step.object;
        if (std.mem.eql(u8, state.get("set").?.string, "all"))
            sandbox.setDisabled(state.get("value").?.bool)
        else
            sandbox.disable_network = state.get("value").?.bool;
        try std.testing.expectEqual(
            state.get("disable_sandbox_filesystem").?.bool,
            sandbox.disable_filesystem,
        );
        try std.testing.expectEqual(state.get("disable_sandbox_syscalls").?.bool, sandbox.disable_syscalls);
        try std.testing.expectEqual(state.get("disable_sandbox_network").?.bool, sandbox.disable_network);
    }
    sandbox.disable_network = true;
    try std.testing.expectEqual(0, sandbox.legacyDisabledState());
    sandbox.disable_filesystem = true;
    try std.testing.expectEqual(1, sandbox.legacyDisabledState());
    sandbox.disable_syscalls = true;
    try std.testing.expectEqual(2, sandbox.legacyDisabledState());
    // Local database initialization creates and validates the recorded format version.
    try std.testing.expect(reference.get("initialization_creates_local_version_file").?.bool);
    _ = try fixture.temporary.dir.statFile(io, "db/local/ALPM_DB_VERSION", .{});
}

fn expectReferencePath(actual: []const u8, expected: []const u8, fixture: Fixture) !void {
    const is_root = std.mem.startsWith(u8, expected, "$ROOT");
    const prefix = if (is_root) fixture.root else fixture.db;
    const suffix = expected[if (is_root) @as(usize, 5) else @as(usize, 3)..];
    const expanded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, suffix });
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings(expanded, actual);
}

test "failed local reload rolls back cache indexes and supports retry" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var owner = try rlpm.Owner.init(io, failing.allocator(), fixture.configuration(), &.{});
    defer owner.deinit() catch unreachable;
    const local = owner.localDatabase().?;
    const previous = (try owner.findPackage(local, "alpha")).?;
    try owner.invalidateDatabase(local);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.loadDatabase(io, local));
    failing.fail_index = std.math.maxInt(usize);
    const db = try owner.database(local);
    try std.testing.expect(!db.status.package_cache_loaded);
    try std.testing.expectEqual(0, db.packages.by_name.count());
    try std.testing.expectEqual(0, db.groups.groups.items.len);
    try owner.loadDatabase(io, local);
    try std.testing.expectEqual(3, (try owner.packageIds(local)).len);
    try std.testing.expectError(error.StalePackageReference, owner.package(previous));
}
