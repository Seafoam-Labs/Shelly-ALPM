const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");
const HttpFixture = @import("http_download_fixture.zig");

const a = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    temporary: std.testing.TmpDir,
    path: [:0]const u8,
    cache: []const u8,
    server: []const u8,

    fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        try temporary.dir.createDirPath(io, "cache");
        try temporary.dir.createDirPath(io, "mirror");
        const path = try temporary.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(path);
        const cache = try std.fmt.allocPrint(a, "{s}/cache", .{path});
        errdefer a.free(cache);
        return .{
            .temporary = temporary,
            .path = path,
            .cache = cache,
            .server = try std.fmt.allocPrint(
                a,
                "file://{s}/mirror",
                .{path},
            ),
        };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.path);
        a.free(self.cache);
        a.free(self.server);
        self.temporary.cleanup();
    }

    fn owner(self: *Fixture) !rlpm.Owner {
        return rlpm.Owner.init(
            io,
            a,
            .{
                .root = self.path,
                .database_path = self.path,
                .cache_directories = &.{self.cache},
            },
            &.{
                .{
                    .database_name = "cachyos",
                    .servers = &.{self.server},
                },
            },
        );
    }

    fn repository(self: *Fixture, version: []const u8) !void {
        const metadata = try std.fmt.allocPrint(
            a,
            "%NAME%\ndemo\n\n%VERSION%\n{s}\n\n%FILENAME%\ndemo.pkg.tar.zst\n\n%CSIZE%\n7\n\n%INSTALLED_DB%\ncachyos\n\n",
            .{version},
        );
        defer a.free(metadata);
        var archive = try Archive.init(&.{.{ .path = "demo-1-1/desc", .contents = metadata }}, .none);
        defer archive.deinit();
        const destination = try std.fmt.allocPrint(a, "{s}/mirror/cachyos.db", .{self.path});
        defer a.free(destination);
        try std.Io.Dir.cwd().copyFile(archive.path, .cwd(), destination, io, .{});
    }
};
test "repository filenames escape reserved URL bytes and retain literal cache names" {
    const cases = [_]struct { name: []const u8, encoded: []const u8 }{
        .{ .name = "glibc-2.44+r50+g1848099f063e-1-x86_64.pkg.tar.zst", .encoded = "glibc-2.44%2Br50%2Bg1848099f063e-1-x86_64.pkg.tar.zst" },
        .{ .name = "libstdc++-16.2.1+r23-2-x86_64.pkg.tar.zst", .encoded = "libstdc%2B%2B-16.2.1%2Br23-2-x86_64.pkg.tar.zst" },
        .{ .name = "literal%2B #?.pkg.tar.zst", .encoded = "literal%252B%20%23%3F.pkg.tar.zst" },
    };
    for (cases) |case| {
        const url = try rlpm.Downloads.joinUrl(a, "https://mirror.test/repo%20name/", case.name);
        defer a.free(url);
        const expected = try std.fmt.allocPrint(a, "https://mirror.test/repo%20name/{s}", .{case.encoded});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, url);
        const name = try rlpm.Downloads.urlFilename(a, url);
        defer a.free(name);
        try std.testing.expectEqualStrings(case.name, name);
        const signature = try rlpm.Downloads.signatureUrl(a, url);
        defer a.free(signature);
        const expected_signature = try std.fmt.allocPrint(a, "{s}.sig", .{expected});
        defer a.free(expected_signature);
        try std.testing.expectEqualStrings(expected_signature, signature);
    }
}

test "repository HTTP downloads encode plus signs in package and detached signature URLs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: HttpFixture = .{
        .server = try address.listen(io, .{ .reuse_address = true }),
        .body = "package",
        .expected_path = "/repo/libstdc%2B%2B-16.2.1%2Br23-2-x86_64.pkg.tar.zst",
    };
    defer server.server.deinit(io);
    var serving = try io.concurrent(HttpFixture.serve, .{&server});
    defer _ = serving.cancel(io) catch {};
    const mirror = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/repo", .{server.server.socket.address.getPort()});
    defer a.free(mirror);
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    const name = "libstdc++-16.2.1+r23-2-x86_64.pkg.tar.zst";
    const files = try rlpm.Downloads.acquire(&owner, io, &.{.{
        .name = name,
        .servers = &.{mirror},
        .policy = .{ .package = .optional, .database = .disabled },
    }});
    defer {
        for (files) |*file| file.deinit();
        a.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings(name, std.fs.path.basename(files[0].path));
    const payload = try std.Io.Dir.cwd().readFileAlloc(io, files[0].path, a, .limited(64));
    defer a.free(payload);
    try std.testing.expectEqualStrings("package", payload);
    try std.testing.expectEqual(@as(usize, 2), server.requests.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), server.signatures.load(.acquire));
    try std.testing.expect(!server.failed.load(.acquire));
}

test "URL fetch publishes a verified sealed file and revalidates cached bytes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg.tar.zst", .data = "package" });
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    const url = try std.fmt.allocPrint(a, "{s}/demo.pkg.tar.zst", .{fixture.server});
    defer a.free(url);
    var file = try owner.fetchPackage(io, url);
    defer file.deinit();
    try std.testing.expect(!file.cached);
    var cached = try owner.fetchPackage(io, url);
    defer cached.deinit();
    try std.testing.expect(cached.cached);
    try std.testing.expectError(
        error.InvalidPackageFilename,
        owner.fetchPackage(
            io,
            "https://example.test/%2e%2e",
        ),
    );
    try std.testing.expectError(
        error.InvalidPackageFilename,
        owner.fetchPackage(
            io,
            "https://example.test/a%2fb",
        ),
    );
    const original = "https://origin.test/demo.pkg.tar.zst";
    const redirected = "https://mirror.test/demo.pkg.tar.zst";
    try std.testing.expectEqualStrings(
        redirected,
        rlpm.Downloads.signatureSource(original, redirected, ".db"),
    );
    try std.testing.expectEqualStrings(
        original,
        rlpm.Downloads.signatureSource(
            original,
            "https://mirror.test/opaque?id=demo.pkg.tar.zst",
            ".db",
        ),
    );
    try std.testing.expectEqualStrings(
        "https://mirror.test/cachyos.custom",
        rlpm.Downloads.signatureSource(
            original,
            "https://mirror.test/cachyos.custom",
            ".custom",
        ),
    );
}
test "refresh preserves CachyOS metadata and stale references change only on update" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    const db = owner.findDatabase("cachyos").?;
    var refreshed = try owner.refreshDatabases(io, false);
    defer refreshed.deinit();
    try refreshed.check();
    try std.testing.expectEqual(.updated, refreshed.databases[0].outcome);
    const reference = (try owner.findPackage(db, "demo")).?;
    try std.testing.expectEqualStrings("cachyos", (try owner.package(reference)).database_name);
    var unchanged = try owner.refreshDatabases(io, false);
    defer unchanged.deinit();
    try unchanged.check();
    try std.testing.expectEqual(.unchanged, unchanged.databases[0].outcome);
    _ = try owner.package(reference);
    try fixture.repository("2-1");
    var forced = try owner.refreshDatabases(io, true);
    defer forced.deinit();
    try forced.check();
    try std.testing.expectError(error.StalePackageReference, owner.package(reference));
}
test "DOWNLOADONLY commits cache without installed mutation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg.tar.zst", .data = "package" });
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var refresh = try owner.refreshDatabases(io, true);
    defer refresh.deinit();
    try refresh.check();
    const tx = try owner.initializeTransaction(io, .{ .download_only = true });
    defer owner.releaseTransaction() catch unreachable;
    try tx.addTarget("demo");
    try tx.prepare();
    try tx.commit();
    try std.testing.expectEqual(.completed, tx.state);
    try std.testing.expectEqual(1, tx.downloaded_files.?.len);
    try std.testing.expectEqual(0, tx.result().packages_committed);
    try std.testing.expectEqual(null, try owner.findPackage(owner.localDatabase().?, "demo"));
}

test "invalid cache is rejected and replaced only after size and digest checks" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "cache/demo.pkg.tar.zst", .data = "bad" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg.tar.zst", .data = "package" });
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var refresh = try owner.refreshDatabases(io, true);
    defer refresh.deinit();
    try refresh.check();
    const tx = try owner.initializeTransaction(io, .{ .download_only = true });
    defer owner.releaseTransaction() catch unreachable;
    try tx.addTarget("demo");
    try tx.prepare();
    const size = try tx.downloadSize();
    try std.testing.expectEqual(7, size.bytes);
    try std.testing.expectEqual(0, size.cached);
    try tx.download();
    const ready = try tx.downloadSize();
    try std.testing.expectEqual(0, ready.bytes);
    try std.testing.expectEqual(1, ready.cached);
    try tx.commit();
}

test "mirror fallback preserves old cache when every candidate has the wrong size" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "cache/demo.pkg.tar.zst", .data = "old" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg.tar.zst", .data = "too large" });
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var refresh = try owner.refreshDatabases(io, true);
    defer refresh.deinit();
    try refresh.check();
    const tx = try owner.initializeTransaction(io, .{ .download_only = true });
    defer owner.releaseTransaction() catch unreachable;
    try tx.addTarget("demo");
    try tx.prepare();
    try std.testing.expectError(error.SizeExceeded, tx.commit());
    try std.testing.expectEqual(.failed, tx.state);
    const bytes = try fixture.temporary.dir.readFileAlloc(io, "cache/demo.pkg.tar.zst", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "refresh aggregates failures and disabled usage while preserving the last good generation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var first = try owner.refreshDatabases(io, true);
    defer first.deinit();
    try first.check();
    const reference = (try owner.findPackage(owner.findDatabase("cachyos").?, "demo")).?;
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/cachyos.db", .data = "invalid" });
    _ = try owner.registerDatabase(.{ .database_name = "missing", .servers = &.{fixture.server} });
    _ = try owner.registerDatabase(.{ .database_name = "disabled", .usage = .{ .sync = false } });
    var failed = try owner.refreshDatabases(io, true);
    defer failed.deinit();
    try std.testing.expectEqual(.failed, failed.databases[0].outcome);
    try std.testing.expectEqual(.failed, failed.databases[1].outcome);
    try std.testing.expectEqual(.skipped, failed.databases[2].outcome);
    _ = try owner.package(reference);
    try owner.reloadDatabase(io, owner.findDatabase("cachyos").?);
    try std.testing.expect((try owner.findPackage(owner.findDatabase("cachyos").?, "demo")) != null);
}

test "refresh lock contention does not discard another owner's lock" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    var first = try fixture.owner();
    defer first.deinit() catch unreachable;
    var second = try fixture.owner();
    defer second.deinit() catch unreachable;
    _ = try first.initializeTransaction(io, .{});
    defer first.releaseTransaction() catch unreachable;
    try std.testing.expectError(error.DatabaseLocked, second.refreshDatabases(io, true));
    try fixture.temporary.dir.access(io, "db.lck", .{});
}

const FetchContext = struct {
    owner: *rlpm.Owner,
    source: []const u8,
    result: rlpm.Callbacks.FetchResult = .updated,
    calls: usize = 0,
    cancel: bool = false,

    fn fetch(ctx: ?*anyopaque, request: rlpm.Callbacks.Fetch) rlpm.Callbacks.FetchError!rlpm.Callbacks.FetchResult {
        const self: *FetchContext = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.owner.setCallbacks(.{})) |_|
            return error.DownloadFailed
        else |err| if (err != error.CallbackReentry)
            return error.DownloadFailed;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const name = rlpm.Downloads.urlFilename(arena.allocator(), request.url) catch
            return error.DownloadFailed;
        const destination = std.fs.path.join(arena.allocator(), &.{ request.destination_directory, name }) catch
            return error.OutOfMemory;
        std.Io.Dir.cwd().copyFile(self.source, .cwd(), destination, io, .{}) catch return error.DownloadFailed;
        if (self.cancel) self.owner.requestCancellation();
        return self.result;
    }
};
test "custom fetch updated and unchanged results run behind the callback guard" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/input", .data = "custom" });
    const source = try std.fmt.allocPrint(a, "{s}/mirror/input", .{fixture.path});
    defer a.free(source);
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var ctx: FetchContext = .{ .owner = &owner, .source = source };
    try owner.setCallbacks(.{ .fetch = FetchContext.fetch, .fetch_context = &ctx });
    var updated = try owner.fetchPackage(io, "custom://mirror/first.pkg");
    defer updated.deinit();
    ctx.result = .unchanged;
    var unchanged = try owner.fetchPackage(io, "custom://mirror/second.pkg");
    defer unchanged.deinit();
    try std.testing.expectEqual(2, ctx.calls);
    ctx.cancel = true;
    try std.testing.expectError(error.Cancelled, owner.fetchPackage(io, "custom://mirror/third.pkg"));
    try std.testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.access(io, "cache/third.pkg", .{}),
    );
}

test "required and oversized optional signatures never become usable cache files" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/pkg", .data = "package" });
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var options = owner.options();
    options.remote_file_signature_policy = .{ .package = .required, .database = .disabled };
    try owner.setOptions(io, options);
    const url = try std.fmt.allocPrint(a, "{s}/pkg", .{fixture.server});
    defer a.free(url);
    try std.testing.expectError(error.SignatureMissing, owner.fetchPackage(io, url));
    try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "cache/pkg", .{}));
    options = owner.options();
    options.remote_file_signature_policy.?.package = .optional;
    try owner.setOptions(io, options);
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "mirror/pkg.sig",
            .data = &@as([16385]u8, @splat(42)),
        },
    );
    if (owner.fetchPackage(io, url)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedSignatureRejection;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "cache/pkg", .{}));
}

test "cache servers precede repository servers and misses fall through" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    try fixture.temporary.dir.createDirPath(io, "cache-server");
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "cache-server/demo.pkg.tar.zst",
            .data = "cache!!",
        },
    );
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg.tar.zst", .data = "package" });
    const server = try std.fmt.allocPrint(a, "file://{s}/cache-server", .{fixture.path});
    defer a.free(server);
    var owner = try rlpm.Owner.init(
        io,
        a,
        .{
            .root = fixture.path,
            .database_path = fixture.path,
            .cache_directories = &.{fixture.cache},
        },
        &.{
            .{
                .database_name = "cachyos",
                .servers = &.{fixture.server},
                .cache_servers = &.{
                    "file:///missing-fixture-directory",
                    server,
                },
            },
        },
    );
    defer owner.deinit() catch unreachable;
    var refresh = try owner.refreshDatabases(io, true);
    defer refresh.deinit();
    try refresh.check();
    const tx = try owner.initializeTransaction(io, .{ .download_only = true });
    defer owner.releaseTransaction() catch unreachable;
    try tx.addTarget("demo");
    try tx.prepare();
    try tx.commit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        tx.downloaded_files.?[0].snapshot.path(),
        a,
        .limited(100),
    );
    defer a.free(bytes);
    try std.testing.expectEqualStrings("cache!!", bytes);
}

test "independent owners see complete published databases with custom extensions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.repository("1-1");
    try fixture.temporary.dir.rename("mirror/cachyos.db", fixture.temporary.dir, "mirror/cachyos.files", io);
    var options: rlpm.OwnerConfiguration = .{
        .root = fixture.path,
        .database_path = fixture.path,
        .database_extension = ".files",
        .cache_directories = &.{fixture.cache},
    };
    var first = try rlpm.Owner.init(
        io,
        a,
        options,
        &.{
            .{
                .database_name = "cachyos",
                .servers = &.{fixture.server},
            },
        },
    );
    defer first.deinit() catch unreachable;
    options.local_database_mode = .read_only;
    var second = try rlpm.Owner.init(
        io,
        a,
        options,
        &.{
            .{
                .database_name = "cachyos",
                .servers = &.{fixture.server},
            },
        },
    );
    defer second.deinit() catch unreachable;
    var refreshed = try first.refreshDatabases(io, true);
    defer refreshed.deinit();
    try refreshed.check();
    const ref = try second.queryPackage(io, second.findDatabase("cachyos").?, "demo");
    try std.testing.expect(ref != null);
}

test "pinned DOWNLOADONLY and refresh outcomes match the recorded library" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("reference/download-oracle.jsonl"), '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const value = parsed.value.object;
        const name = value.get("name").?.string;
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.repository("1-1");
        var policy = rlpm.OwnerConfiguration.disabled_signatures;
        if (std.mem.eql(u8, name, "required-signature")) policy.package = .required;
        if (std.mem.eql(u8, name, "optional-signature")) policy.package = .optional;
        const wrong_digest = std.mem.eql(u8, name, "digest-mismatch");
        if (wrong_digest) {
            var archive = try Archive.init(
                &.{
                    .{
                        .path = "demo-1-1/desc",
                        .contents = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%FILENAME%\ndemo.pkg.tar.zst\n\n%CSIZE%\n7\n\n%SHA256SUM%\n0000000000000000000000000000000000000000000000000000000000000000\n\n",
                    },
                },
                .none,
            );
            defer archive.deinit();
            const path = try std.fmt.allocPrint(a, "{s}/mirror/cachyos.db", .{fixture.path});
            defer a.free(path);
            try std.Io.Dir.cwd().copyFile(archive.path, .cwd(), path, io, .{});
        }
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg.tar.zst", .data = "package" });
        const disabled = std.mem.eql(u8, name, "refresh-disabled");
        var owner = try rlpm.Owner.init(
            io,
            a,
            .{
                .root = fixture.path,
                .database_path = fixture.path,
                .cache_directories = &.{fixture.cache},
            },
            &.{
                .{
                    .database_name = "cachyos",
                    .servers = &.{fixture.server},
                    .signature_policy = policy,
                    .usage = .{ .sync = !disabled },
                },
            },
        );
        defer owner.deinit() catch unreachable;
        if (std.mem.eql(u8, name, "refresh-lock")) {
            try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db.lck", .data = "" });
            try std.testing.expectEqual(-1, value.get("refresh").?.integer);
            try std.testing.expectError(error.DatabaseLocked, owner.refreshDatabases(io, false));
            continue;
        }
        var refresh = try owner.refreshDatabases(io, false);
        defer refresh.deinit();
        try refresh.check();
        if (disabled) {
            try std.testing.expectEqual(.skipped, refresh.databases[0].outcome);
            continue;
        }
        var unchanged = try owner.refreshDatabases(io, false);
        defer unchanged.deinit();
        try unchanged.check();
        try std.testing.expectEqual(1, value.get("unchanged").?.integer);
        try std.testing.expectEqual(.unchanged, unchanged.databases[0].outcome);
        const tx = try owner.initializeTransaction(io, .{ .download_only = true });
        defer owner.releaseTransaction() catch unreachable;
        try tx.addTarget("demo");
        try tx.prepare();
        try std.testing.expectEqual(
            @as(u64, @intCast(value.get("download_size").?.integer)),
            (try tx.downloadSize()).bytes,
        );
        if (value.get("commit").?.integer == 0) {
            try tx.commit();
        } else {
            try std.testing.expectError(
                if (wrong_digest) error.ChecksumMismatch else error.SignatureMissing,
                tx.commit(),
            );
            // Planned safety difference: rejected bytes stay in private staging.
            try std.testing.expectError(
                error.FileNotFound,
                fixture.temporary.dir.access(
                    io,
                    "cache/demo.pkg.tar.zst",
                    .{},
                ),
            );
        }
        try std.testing.expectEqual(null, try owner.findPackage(owner.localDatabase().?, "demo"));
    }
}

const DownloadEvents = struct {
    owner: *rlpm.Owner,
    thread: @TypeOf(std.os.linux.gettid()),
    initialized: usize = 0,
    completed: usize = 0,
    wrong_thread: bool = false,
    reentry_allowed: bool = false,
    cancel: bool = false,

    fn callback(ctx: ?*anyopaque, event: rlpm.Callbacks.Download) void {
        const self: *DownloadEvents = @ptrCast(@alignCast(ctx.?));
        self.wrong_thread = self.wrong_thread or self.thread != std.os.linux.gettid();
        if (self.owner.setCallbacks(.{})) |_| self.reentry_allowed = true else |err| {
            self.reentry_allowed = self.reentry_allowed or err != error.CallbackReentry;
        }
        switch (event) {
            .init => {
                self.initialized += 1;
                if (self.cancel) self.owner.requestCancellation();
            },
            .completed => self.completed += 1,
            else => {},
        }
    }
};
test "URL batches marshal logical events to Owner and finish started jobs after cancellation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var options = owner.options();
    options.parallel_downloads = 3;
    try owner.setOptions(io, options);
    var events: DownloadEvents = .{ .owner = &owner, .thread = std.os.linux.gettid() };
    try owner.setCallbacks(.{ .download = DownloadEvents.callback, .download_context = &events });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var urls: [3][]const u8 = undefined;
    for (&urls, 0..) |*url, index| {
        const path = try std.fmt.allocPrint(arena.allocator(), "mirror/{d}.pkg", .{index});
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = path, .data = "package" });
        url.* = try std.fmt.allocPrint(arena.allocator(), "{s}/{d}.pkg", .{ fixture.server, index });
    }
    var files = try owner.fetchPackageUrls(io, &urls);
    defer files.deinit();
    try std.testing.expectEqual(3, files.files.len);
    try std.testing.expectEqual(3, events.initialized);
    try std.testing.expectEqual(3, events.completed);
    try std.testing.expect(!events.wrong_thread and !events.reentry_allowed);
    events.cancel = true;
    try std.testing.expectError(error.Cancelled, owner.fetchPackage(io, "file:///missing/another.pkg"));
    try std.testing.expectEqual(4, events.initialized);
    try std.testing.expectEqual(4, events.completed);
}

test "package and repository HTTP queues bound overlapping payload signature and mirror requests" {
    var archive = try Archive.init(
        &.{
            .{
                .path = "demo-1-1/desc",
                .contents = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive.path, a, .limited(1024 * 1024));
    defer a.free(bytes);
    for ([_]u8{ 1, 3, 10 }) |limit|
        for ([_]bool{ false, true }) |database| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
            var server: HttpFixture = .{
                .server = try address.listen(io, .{ .reuse_address = true }),
                .body = bytes,
            };
            defer server.server.deinit(io);
            var serving = try io.concurrent(HttpFixture.serve, .{&server});
            defer _ = serving.cancel(io) catch {};
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const alloc = arena.allocator();
            const port = server.server.socket.address.getPort();
            const mirrors = [_][]const u8{
                try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/missing", .{port}),
                try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/good", .{port}),
            };
            const policy: rlpm.SignaturePolicy = .{ .package = .optional, .database = .optional };
            var owner = try rlpm.Owner.init(
                io,
                a,
                .{
                    .root = fixture.path,
                    .database_path = fixture.path,
                    .cache_directories = &.{fixture.cache},
                    .parallel_downloads = limit,
                },
                &.{},
            );
            defer owner.deinit() catch unreachable;
            var requests: [12]rlpm.Downloads.Request = undefined;
            for (&requests, 0..) |*request, index| {
                const name = try std.fmt.allocPrint(alloc, "repo{d}", .{index});
                if (database)
                    _ = try owner.registerDatabase(
                        .{
                            .database_name = name,
                            .servers = &mirrors,
                            .signature_policy = policy,
                        },
                    );
                request.* = .{
                    .name = try std.fmt.allocPrint(alloc, "{s}.pkg", .{name}),
                    .servers = mirrors[1..],
                    .cache_servers = mirrors[0..1],
                    .policy = policy,
                };
            }
            if (database) {
                var result = try owner.refreshDatabases(io, true);
                defer result.deinit();
                try result.check();
                try std.testing.expectEqual(12, result.databases.len);
            } else {
                const files = try rlpm.Downloads.acquire(&owner, io, &requests);
                defer a.free(files);
                for (files) |*file|
                    file.deinit();
            }
            const peak = server.peak.load(.acquire);
            try std.testing.expect(peak <= limit);
            try std.testing.expect(if (limit == 1) peak == 1 else peak > 1);
            try std.testing.expectEqual(12, server.signatures.load(.acquire));
            try std.testing.expectEqual(36, server.requests.load(.acquire));
            try std.testing.expect(!server.failed.load(.acquire));
        };
}

test "fast transfer completion reaches the owner before a slow response is released" {
    const Capture = struct {
        server: *HttpFixture,
        owner: *rlpm.Owner,
        thread: @TypeOf(std.os.linux.gettid()),
        transferred: usize = 0,
        accepted: usize = 0,
        wrong_thread: bool = false,

        fn receive(data: ?*anyopaque, value: rlpm.Callbacks.Download) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.wrong_thread = self.wrong_thread or self.thread != std.os.linux.gettid();
            switch (value) {
                .transferred => |update| {
                    std.testing.expectEqual(0, self.accepted) catch unreachable;
                    self.transferred += 1;
                    if (std.mem.startsWith(u8, update.name, "fast."))
                        self.server.fast_reported.store(
                            true,
                            .release,
                        );
                },
                .completed => self.accepted += 1,
                .progress => |update| if (std.mem.startsWith(u8, update.name, "fast.")) {
                    std.testing.expect(!self.server.fast_reported.load(.acquire)) catch unreachable;
                },
                else => {},
            }
            std.testing.expectError(error.CallbackReentry, self.owner.setCallbacks(.{})) catch unreachable;
        }
    };
    var archive = try Archive.init(
        &.{
            .{
                .path = "demo-1-1/desc",
                .contents = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive.path, a, .limited(1024 * 1024));
    defer a.free(bytes);
    for ([_]bool{ false, true }) |database| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server: HttpFixture = .{
            .server = try address.listen(io, .{ .reuse_address = true }),
            .body = bytes,
            .gate_slow = true,
            .unknown_length = true,
        };
        defer server.server.deinit(io);
        var serving = try io.concurrent(HttpFixture.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        const url = try std.fmt.allocPrint(
            a,
            "http://127.0.0.1:{d}",
            .{server.server.socket.address.getPort()},
        );
        defer a.free(url);
        var owner = try rlpm.Owner.init(
            io,
            a,
            .{
                .root = fixture.path,
                .database_path = fixture.path,
                .cache_directories = &.{fixture.cache},
                .parallel_downloads = 3,
            },
            &.{},
        );
        defer owner.deinit() catch unreachable;
        var capture: Capture = .{
            .server = &server,
            .owner = &owner,
            .thread = std.os.linux.gettid(),
        };
        try owner.setCallbacks(.{ .download = Capture.receive, .download_context = &capture });
        if (database) {
            for ([_][]const u8{ "slow", "fast" }) |name|
                _ = try owner.registerDatabase(
                    .{
                        .database_name = name,
                        .servers = &.{url},
                    },
                );
            var result = try owner.refreshDatabases(io, true);
            defer result.deinit();
            try result.check();
        } else {
            const files = try rlpm.Downloads.acquire(&owner, io, &.{
                .{
                    .name = "slow.pkg",
                    .servers = &.{url},
                    .policy = rlpm.OwnerConfiguration.disabled_signatures,
                },
                .{
                    .name = "fast.pkg",
                    .servers = &.{url},
                    .policy = rlpm.OwnerConfiguration.disabled_signatures,
                },
            });
            defer a.free(files);
            for (files) |*file|
                file.deinit();
        }
        try std.testing.expectEqual(2, capture.transferred);
        try std.testing.expectEqual(2, capture.accepted);
        try std.testing.expect(!capture.wrong_thread and !server.timed_out.load(.acquire));
    }
}

const AcceptanceEvents = struct {
    owner: *rlpm.Owner,
    started: usize = 0,
    transferred: usize = 0,
    completed: usize = 0,
    accepted: usize = 0,
    verification_failures: usize = 0,
    last_attempt: u32 = 0,
    cancel_stage: ?@FieldType(@FieldType(rlpm.Callbacks.Download, "processing"), "stage") = null,
    cancel_retry: bool = false,

    fn receive(data: ?*anyopaque, value: rlpm.Callbacks.Download) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (value) {
            .started => |update| {
                self.started += 1;
                std.testing.expect(update.attempt > self.last_attempt) catch unreachable;
                self.last_attempt = update.attempt;
                if (self.cancel_retry and update.attempt == 2) self.owner.requestCancellation();
            },
            .transferred => |update| {
                if (update.result != .failed) self.transferred += 1;
            },
            .processing => |update| {
                if (update.stage == .verification and update.boundary == .failed)
                    self.verification_failures += 1;
                if (self.cancel_stage == update.stage and update.boundary == .start)
                    self.owner.requestCancellation();
            },
            .completed => |update| {
                self.completed += 1;
                if (update.result != .failed) self.accepted += 1;
            },
            else => {},
        }
    }
};

test "rejected database candidates reopen a transfer attempt and retain one acquisition result" {
    for ([_]bool{ false, true }) |cancel| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.repository("1-1");
        try fixture.temporary.dir.createDirPath(io, "bad");
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = "bad/cachyos.db", .data = "invalid archive" });
        const bad = try std.fmt.allocPrint(a, "file://{s}/bad", .{fixture.path});
        defer a.free(bad);
        var owner = try rlpm.Owner.init(
            io,
            a,
            .{
                .root = fixture.path,
                .database_path = fixture.path,
                .cache_directories = &.{fixture.cache},
            },
            &.{
                .{
                    .database_name = "cachyos",
                    .servers = &.{ bad, fixture.server },
                },
            },
        );
        defer owner.deinit() catch unreachable;
        var capture: AcceptanceEvents = .{ .owner = &owner, .cancel_retry = cancel };
        try owner.setCallbacks(.{ .download = AcceptanceEvents.receive, .download_context = &capture });
        var result = try owner.refreshDatabases(io, true);
        defer result.deinit();
        if (cancel) {
            try std.testing.expectError(error.Cancelled, result.check());
            try std.testing.expectEqual(0, capture.accepted);
            try std.testing.expectError(
                error.FileNotFound,
                fixture.temporary.dir.access(
                    io,
                    "sync/cachyos.db",
                    .{},
                ),
            );
        } else {
            try result.check();
            try std.testing.expectEqual(1, capture.accepted);
            try std.testing.expectEqual(2, capture.transferred);
            try std.testing.expect((try owner.findPackage(owner.findDatabase("cachyos").?, "demo")) != null);
        }
        try std.testing.expectEqual(2, capture.started);
        try std.testing.expectEqual(1, capture.completed);
        try std.testing.expectEqual(1, capture.verification_failures);
        try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "db.lck", .{}));
    }
}

test "transferred packages with bad digests fail acceptance without publishing cache bytes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg", .data = "package" });
    var owner = try fixture.owner();
    defer owner.deinit() catch unreachable;
    var version = try rlpm.Version.init("1-1", a);
    defer version.deinit(a);
    const package: rlpm.Package = .{
        .name = "demo",
        .version = version,
        .database_name = "core",
        .compressed_size = 7,
        .sha256_sum = "0000000000000000000000000000000000000000000000000000000000000000",
    };
    var capture: AcceptanceEvents = .{ .owner = &owner };
    try owner.setCallbacks(.{ .download = AcceptanceEvents.receive, .download_context = &capture });
    try std.testing.expectError(
        error.ChecksumMismatch,
        rlpm.Downloads.acquire(
            &owner,
            io,
            &.{
                .{
                    .name = "demo.pkg",
                    .package = &package,
                    .servers = &.{fixture.server},
                    .policy = rlpm.OwnerConfiguration.disabled_signatures,
                },
            },
        ),
    );
    try std.testing.expectEqual(1, capture.transferred);
    try std.testing.expectEqual(1, capture.verification_failures);
    try std.testing.expectEqual(1, capture.completed);
    try std.testing.expectEqual(0, capture.accepted);
    try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "cache/demo.pkg", .{}));
}

test "cancellation at verification and publication boundaries leaves packages and databases unpublished" {
    const Stage = @FieldType(@FieldType(rlpm.Callbacks.Download, "processing"), "stage");
    for ([_]Stage{ .verification, .publication }) |stage|
        for ([_]bool{ false, true }) |database| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.repository("1-1");
            try fixture.temporary.dir.writeFile(io, .{ .sub_path = "mirror/demo.pkg", .data = "package" });
            var owner = try fixture.owner();
            defer owner.deinit() catch unreachable;
            var capture: AcceptanceEvents = .{ .owner = &owner, .cancel_stage = stage };
            try owner.setCallbacks(.{ .download = AcceptanceEvents.receive, .download_context = &capture });
            if (database) {
                var result = try owner.refreshDatabases(io, true);
                defer result.deinit();
                try std.testing.expectError(error.Cancelled, result.check());
                try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "db.lck", .{}));
                try std.testing.expectError(
                    error.FileNotFound,
                    fixture.temporary.dir.access(
                        io,
                        "sync/cachyos.db",
                        .{},
                    ),
                );
            } else {
                const url = try std.fmt.allocPrint(a, "{s}/demo.pkg", .{fixture.server});
                defer a.free(url);
                try std.testing.expectError(error.Cancelled, owner.fetchPackage(io, url));
                try std.testing.expectError(
                    error.FileNotFound,
                    fixture.temporary.dir.access(
                        io,
                        "cache/demo.pkg",
                        .{},
                    ),
                );
            }
            try std.testing.expectEqual(1, capture.transferred);
            try std.testing.expectEqual(1, capture.completed);
            try std.testing.expectEqual(0, capture.accepted);
        };
}

test "cancellation interrupts an active HTTP request and leaves queued acquisitions unpublished" {
    const Cancel = struct {
        server: *HttpFixture,
        owner: *rlpm.Owner,

        fn run(self: *@This()) void {
            const start = std.Io.Clock.awake.now(io);
            while (self.server.active.load(.acquire) == 0) {
                if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 3000) break;
                io.sleep(.fromMilliseconds(5), .awake) catch break;
            }
            self.owner.requestCancellation();
        }
    };
    for ([_]bool{ false, true }) |database| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server: HttpFixture = .{
            .server = try address.listen(io, .{ .reuse_address = true }),
            .body = "unused",
            .gate_slow = true,
        };
        defer server.server.deinit(io);
        var serving = try io.concurrent(HttpFixture.serve, .{&server});
        defer _ = serving.cancel(io) catch {};
        const url = try std.fmt.allocPrint(
            a,
            "http://127.0.0.1:{d}",
            .{server.server.socket.address.getPort()},
        );
        defer a.free(url);
        var owner = try rlpm.Owner.init(
            io,
            a,
            .{
                .root = fixture.path,
                .database_path = fixture.path,
                .cache_directories = &.{fixture.cache},
                .parallel_downloads = 1,
            },
            &.{},
        );
        defer owner.deinit() catch unreachable;
        var capture: DownloadEvents = .{ .owner = &owner, .thread = std.os.linux.gettid() };
        try owner.setCallbacks(.{ .download = DownloadEvents.callback, .download_context = &capture });
        var cancel: Cancel = .{ .server = &server, .owner = &owner };
        var cancelling = try io.concurrent(Cancel.run, .{&cancel});
        defer cancelling.await(io);
        if (database) {
            for ([_][]const u8{ "slow", "queued" }) |name|
                _ = try owner.registerDatabase(
                    .{
                        .database_name = name,
                        .servers = &.{url},
                    },
                );
            var result = try owner.refreshDatabases(io, true);
            defer result.deinit();
            try std.testing.expectError(error.Cancelled, result.check());
            for (result.databases) |entry|
                try std.testing.expectEqual(.failed, entry.outcome);
            try std.testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "db.lck", .{}));
        } else {
            try std.testing.expectError(error.Cancelled, rlpm.Downloads.acquire(&owner, io, &.{
                .{
                    .name = "slow.pkg",
                    .servers = &.{url},
                    .policy = rlpm.OwnerConfiguration.disabled_signatures,
                },
                .{
                    .name = "queued.pkg",
                    .servers = &.{url},
                    .policy = rlpm.OwnerConfiguration.disabled_signatures,
                },
            }));
            try std.testing.expectError(
                error.FileNotFound,
                fixture.temporary.dir.access(
                    io,
                    "cache/queued.pkg",
                    .{},
                ),
            );
        }
        try std.testing.expectEqual(1, server.requests.load(.acquire));
        try std.testing.expectEqual(2, capture.initialized);
        try std.testing.expectEqual(2, capture.completed);
        try std.testing.expect(!server.timed_out.load(.acquire));
    }
}
