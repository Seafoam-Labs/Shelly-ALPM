//! Private-root lifecycle tests; no libalpm, network, or package mutations.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const Archive = @import("archive_fixture.zig");

const a = std.testing.allocator;
const io = std.testing.io;
extern "c" fn rlpm_test_contender([*:0]const u8) c_int;
extern "c" fn rlpm_test_writer([*:0]const u8, *c_int, *c_int) c_int;
extern "c" fn rlpm_test_finish_writer(c_int, c_int) c_int;

const Fixture = struct {
    temporary: std.testing.TmpDir,
    path: [:0]u8,

    fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        try temporary.dir.createDirPath(io, "local/demo-1-1");
        try temporary.dir.writeFile(io, .{ .sub_path = "local/ALPM_DB_VERSION", .data = "9\n" });
        try temporary.dir.writeFile(
            io,
            .{
                .sub_path = "local/demo-1-1/desc",
                .data = "%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%REASON%\n0\n\n",
            },
        );
        return .{ .temporary = temporary, .path = try temporary.dir.realPathFileAlloc(io, ".", a) };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.path);
        self.temporary.cleanup();
    }

    fn owner(self: *Fixture, allocator: std.mem.Allocator) !rlpm.Owner {
        return rlpm.Owner.init(
            io,
            allocator,
            .{
                .root = self.path,
                .database_path = self.path,
                .local_file_signature_policy = .{
                    .package = .disabled,
                    .database = .disabled,
                },
            },
            &.{},
        );
    }

    fn locked(self: *Fixture) bool {
        self.temporary.dir.access(io, "db.lck", .{}) catch return false;
        return true;
    }
};

test "transaction locks at init, freezes configuration, and releases uncommitted plans" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    const previous = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    const tx = try owner.initializeTransaction(io, .{});
    try std.testing.expect(fixture.locked());
    const lock_stat = try fixture.temporary.dir.statFile(io, "db.lck", .{});
    try std.testing.expectEqual(0, lock_stat.size);
    try std.testing.expectEqual(0, lock_stat.permissions.toMode() & 0o777);
    try std.testing.expectError(error.StalePackageReference, owner.package(previous));
    try std.testing.expectError(error.InvalidTransactionState, tx.commit());
    try std.testing.expectError(error.InvalidTransactionState, tx.interrupt());
    try std.testing.expectError(error.TransactionActive, owner.initializeTransaction(io, .{}));
    try std.testing.expectError(error.TransactionActive, owner.deinit());
    try std.testing.expectError(error.TransactionActive, owner.setOptions(io, owner.options()));
    try std.testing.expectError(error.TransactionActive, owner.setCallbacks(.{}));
    try std.testing.expectError(error.TransactionActive, owner.reloadDatabase(io, owner.localDatabase().?));
    try std.testing.expectError(error.TransactionActive, owner.unregisterDatabase(owner.localDatabase().?));
    try tx.remove("demo");
    try tx.remove("demo");
    try tx.prepare();
    try std.testing.expectEqual(.prepared, tx.state);
    try std.testing.expectEqual(1, tx.plan().?.removals.len);
    try std.testing.expectError(error.InvalidTransactionState, tx.remove("demo"));
    try std.testing.expectError(error.InvalidTransactionState, tx.prepare());
    try std.testing.expectEqual(.prepared, tx.state);
    try std.testing.expectEqual(0, tx.result().packages_committed);
    try owner.releaseTransaction();
    try std.testing.expect(!fixture.locked());
    try std.testing.expectError(error.TransactionNotInitialized, owner.releaseTransaction());
}

test "empty native prepare remains initialized and NOLOCK never commits" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    var tx = try owner.initializeTransaction(io, .{});
    try tx.prepare();
    try std.testing.expectEqual(.initialized, tx.state);
    try std.testing.expectError(error.InvalidTransactionState, tx.commit());
    try owner.releaseTransaction();
    tx = try owner.initializeTransaction(io, .{ .no_lock = true });
    try std.testing.expect(!fixture.locked());
    try tx.remove("demo");
    try tx.prepare();
    try std.testing.expectError(error.TransactionNotLocked, tx.commit());
    try owner.releaseTransaction();
}

test "losing owner and explicit unlock preserve foreign locks" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.owner(a);
    defer first.deinit() catch unreachable;
    var second = try fixture.owner(a);
    defer second.deinit() catch unreachable;
    _ = try first.initializeTransaction(io, .{});
    try std.testing.expectError(error.DatabaseLocked, second.initializeTransaction(io, .{}));
    try second.unlock();
    try std.testing.expect(fixture.locked());
    try first.releaseTransaction();
    const tx = try second.initializeTransaction(io, .{});
    try tx.remove("demo");
    try tx.prepare();
    try second.unlock();
    try std.testing.expectError(error.LockNotHeld, tx.commit());
    try second.releaseTransaction();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db.lck", .data = "foreign" });
    try first.unlock();
    try std.testing.expectError(error.DatabaseLocked, first.initializeTransaction(io, .{}));
    try std.testing.expect(fixture.locked());
}

test "replacement lock survives release and stale database fails before commit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    _ = try owner.initializeTransaction(io, .{});
    try fixture.temporary.dir.deleteFile(io, "db.lck");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "db.lck", .data = "replacement" });
    try std.testing.expectError(error.LockOwnershipLost, owner.releaseTransaction());
    try std.testing.expect(owner.transaction() == null);
    try std.testing.expect(fixture.locked());
    try fixture.temporary.dir.deleteFile(io, "db.lck");
    const tx = try owner.initializeTransaction(io, .{});
    try tx.remove("demo");
    try tx.prepare();
    try fixture.temporary.dir.writeFile(
        io,
        .{
            .sub_path = "local/demo-1-1/desc",
            .data = "%NAME%\ndemo\n\n%VERSION%\n2-1\n\n",
        },
    );
    try std.testing.expectError(error.StaleDatabaseState, tx.commit());
    try std.testing.expectEqual(.failed, tx.state);
    try owner.releaseTransaction();
}

test "cancelled and failed prepare retain diagnostics and remain releasable" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    var tx = try owner.initializeTransaction(io, .{});
    try tx.addTarget("absent");
    try std.testing.expectError(error.TargetNotFound, tx.prepare());
    try std.testing.expectEqual(.failed, tx.state);
    try std.testing.expect(tx.plan().?.failure != null);
    try owner.releaseTransaction();
    tx = try owner.initializeTransaction(io, .{});
    owner.requestCancellation();
    try std.testing.expectError(error.Cancelled, tx.prepare());
    try std.testing.expectEqual(.interrupted, tx.state);
    try tx.interrupt();
    try owner.releaseTransaction();
    try std.testing.expect(!fixture.locked());
    try owner.resetCancellation();
}

test "archive ownership transfers once and duplicate rejection retains caller resources" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    var archive = try Archive.init(
        &.{
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = archive\npkgver = 1-1\narch = any\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    var first: ?rlpm.Package = try owner.loadPackage(io, archive.path, .local_file, .{});
    defer if (first) |*pkg| pkg.deinit();
    const archive_fd = first.?.verified_archive.?.fd;
    var second: ?rlpm.Package = try owner.loadPackage(io, archive.path, .local_file, .{});
    defer if (second) |*pkg| pkg.deinit();
    const tx = try owner.initializeTransaction(io, .{});
    try tx.takeArchive(&first);
    try std.testing.expect(first == null);
    try std.testing.expectError(error.DuplicateTarget, tx.takeArchive(&second));
    try std.testing.expectEqual(error.DuplicateTarget, owner.diagnostic().?.cause);
    try std.testing.expect(second.?.verified_archive != null);
    try tx.prepare();
    try std.testing.expectEqualStrings(
        "archive",
        tx.plan().?.package(tx.plan().?.additions[0].package).name,
    );
    const plan_fd = tx.plan().?.package(tx.plan().?.additions[0].package).verified_archive.?.fd;
    try owner.releaseTransaction();
    try std.testing.expectEqual(-1, std.c.fcntl(archive_fd, std.c.F.GETFD));
    try std.testing.expectEqual(-1, std.c.fcntl(plan_fd, std.c.F.GETFD));
}

fn allocationLifecycle(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var owner = try fixture.owner(allocator);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    try tx.remove("demo");
    try tx.prepare();
}
test "transaction init and preparation allocation failures always release lock and resources" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationLifecycle, .{&fixture});
    try std.testing.expect(!fixture.locked());
}

test "another process contends with Owner in both lock acquisition orders" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    const path = try a.dupeZ(u8, owner.lock_file);
    defer a.free(path);
    _ = try owner.initializeTransaction(io, .{});
    try std.testing.expectEqual(0, rlpm_test_contender(path));
    try std.testing.expect(fixture.locked());
    try owner.releaseTransaction();
    var writer: c_int = undefined;
    var signal: c_int = undefined;
    try std.testing.expectEqual(0, rlpm_test_writer(path, &writer, &signal));
    defer std.testing.expectEqual(0, rlpm_test_finish_writer(writer, signal)) catch unreachable;
    try std.testing.expectError(error.DatabaseLocked, owner.initializeTransaction(io, .{}));
    try owner.unlock();
    try std.testing.expect(fixture.locked());
}

test "lifecycle and prepare event order with callback reentry and cancellation" {
    const Capture = struct {
        owner: *rlpm.Owner,
        items: [20][]const u8 = undefined,
        count: usize = 0,
        cancel_phase: bool = false,

        fn event(data: ?*anyopaque, value: rlpm.Callbacks.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            std.testing.expectError(error.CallbackReentry, self.owner.releaseTransaction()) catch unreachable;
            const text: []const u8 = switch (value) {
                .lifecycle => |result| @tagName(result.state),
                .phase => |phase| if (phase.boundary == .start) "dependency start" else "dependency done",
                else => "other",
            };
            self.items[self.count] = text;
            self.count += 1;
            if (self.cancel_phase and value == .phase) self.owner.requestCancellation();
        }
    };
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    var capture: Capture = .{ .owner = &owner };
    try owner.setCallbacks(.{ .event = Capture.event, .event_context = &capture });
    var tx = try owner.initializeTransaction(io, .{});
    try tx.remove("demo");
    try tx.prepare();
    try owner.releaseTransaction();
    const expected = [_][]const u8{
        "initialized",
        "preparing",
        "dependency start",
        "dependency done",
        "prepared",
        "released",
    };
    try std.testing.expectEqual(expected.len, capture.count);
    for (expected, capture.items[0..capture.count]) |left, right|
        try std.testing.expectEqualStrings(left, right);
    capture.count = 0;
    capture.cancel_phase = true;
    tx = try owner.initializeTransaction(io, .{});
    try tx.remove("demo");
    try std.testing.expectError(error.Cancelled, tx.prepare());
    try std.testing.expectEqual(.interrupted, tx.state);
    try owner.releaseTransaction();
    try std.testing.expectEqualStrings("interrupted", capture.items[3]);
    try std.testing.expectEqualStrings("released", capture.items[4]);
}

test "OwnedQuestion snapshots metadata through source teardown and validates answers" {
    var arena = std.heap.ArenaAllocator.init(a);
    var pkg: rlpm.Package = .{
        .name = try arena.allocator().dupe(u8, "temporary"),
        .version = try rlpm.Version.init("1-1", arena.allocator()),
        .origin = .archive,
        .database_name = "file",
    };
    const ref: rlpm.PackageRef = .{
        .database = .{ .owner = @enumFromInt(1), .id = .archive },
        .generation = 1,
        .id = @enumFromInt(0),
    };
    var question: rlpm.Callbacks.Question = .{
        .select_provider = .{
            .dependency = try rlpm.PackageRelation.parse("virtual>=1"),
            .candidates = &.{ref},
            .views = &.{.{ .reference = ref, .package = &pkg }},
        },
    };
    var owned = try rlpm.OwnedQuestion.init(a, question);
    defer owned.deinit();
    arena.deinit();
    try std.testing.expectEqualStrings("temporary", owned.question.select_provider.views[0].package.name);
    try std.testing.expectEqualStrings("1-1", owned.question.select_provider.views[0].package.version.raw);
    try std.testing.checkAllAllocationFailures(a, copyQuestion, .{owned.question});
    owned.question.select_provider.selected = 10;
    try std.testing.expectError(
        error.InvalidAnswer,
        rlpm.OwnedQuestion.applyAnswer(&question, owned.question),
    );
    try std.testing.expectError(
        error.InvalidAnswer,
        rlpm.OwnedQuestion.applyAnswer(
            &question,
            .{
                .import_key = .{ .key = .{ .fingerprint = "key" } },
            },
        ),
    );
    try std.testing.expectEqual(0, question.select_provider.selected);
}

fn copyQuestion(allocator: std.mem.Allocator, question: rlpm.Callbacks.Question) !void {
    var owned = try rlpm.OwnedQuestion.init(allocator, question);
    defer owned.deinit();
}

const OracleCase = struct {
    name: []const u8,
    flags: u32 = 0,
    dependent: bool = false,
    missing: bool = false,
    skip: bool = false,
    same: bool = false,
    trace: []const struct {
        action: []const u8,
        @"error": ?[]const u8,
        events: []const []const u8,
        locked: bool,
        mode: ?u32,
        size: ?u64,
    },
};

const OracleCapture = struct {
    skip: bool,
    events: [20][]const u8 = undefined,
    count: usize = 0,

    fn question(data: ?*anyopaque, q: *rlpm.Callbacks.Question) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        if (q.* == .remove_packages) q.remove_packages.skip = self.skip;
    }

    fn event(data: ?*anyopaque, value: rlpm.Callbacks.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        if (value != .phase) return;
        const phase = value.phase;
        self.events[self.count] = switch (phase.phase) {
            .dependencies => if (phase.boundary == .start)
                "ALPM_EVENT_CHECKDEPS_START"
            else
                "ALPM_EVENT_CHECKDEPS_DONE",
            .resolve_dependencies => if (phase.boundary == .start)
                "ALPM_EVENT_RESOLVEDEPS_START"
            else
                "ALPM_EVENT_RESOLVEDEPS_DONE",
            .inter_conflicts => if (phase.boundary == .start)
                "ALPM_EVENT_INTERCONFLICTS_START"
            else
                "ALPM_EVENT_INTERCONFLICTS_DONE",
            else => "unexpected",
        };
        self.count += 1;
    }
};

fn oracleAction(
    action: []const u8,
    owner: *rlpm.Owner,
    fixture: *Fixture,
    case: OracleCase,
    archive: *Archive,
) !void {
    if (std.mem.eql(u8, action, "init")) {
        _ = try owner.initializeTransaction(io, try rlpm.TransactionFlags.fromBits(case.flags));
        return;
    }
    if (std.mem.eql(u8, action, "release")) return owner.releaseTransaction();
    if (std.mem.eql(u8, action, "unlock")) return owner.unlock();
    if (std.mem.eql(u8, action, "compete")) {
        var competitor = try fixture.owner(a);
        defer competitor.deinit() catch unreachable;
        _ = try competitor.initializeTransaction(io, .{});
        try competitor.releaseTransaction();
        return;
    }
    const tx = owner.active_transaction orelse return error.TransactionNotInitialized;
    if (std.mem.eql(u8, action, "prepare")) return tx.prepare();
    if (std.mem.eql(u8, action, "commit")) return tx.commit();
    if (std.mem.eql(u8, action, "interrupt")) return tx.interrupt();
    if (std.mem.eql(u8, action, "remove")) return tx.remove("demo");
    if (std.mem.eql(u8, action, "archive")) {
        var input: ?rlpm.Package = try owner.loadPackage(io, archive.path, .local_file, .{});
        defer if (input) |*pkg| pkg.deinit();
        return tx.takeArchive(&input);
    }
    return error.UnexpectedAction;
}

fn oracleError(name: []const u8) anyerror {
    const Mapping = struct {
        native: []const u8,
        result: anyerror,
    };
    for ([_]Mapping{
        .{ .native = "ALPM_ERR_TRANS_NULL", .result = error.TransactionNotInitialized },
        .{ .native = "ALPM_ERR_TRANS_NOT_NULL", .result = error.TransactionActive },
        .{ .native = "ALPM_ERR_TRANS_TYPE", .result = error.InvalidTransactionState },
        .{ .native = "ALPM_ERR_TRANS_NOT_PREPARED", .result = error.InvalidTransactionState },
        .{ .native = "ALPM_ERR_TRANS_NOT_INITIALIZED", .result = error.InvalidTransactionState },
        .{ .native = "ALPM_ERR_TRANS_NOT_LOCKED", .result = error.TransactionNotLocked },
        .{ .native = "ALPM_ERR_HANDLE_LOCK", .result = error.DatabaseLocked },
        .{ .native = "ALPM_ERR_UNSATISFIED_DEPS", .result = error.UnsatisfiedDependencies },
    }) |mapping|
        if (std.mem.eql(u8, name, mapping.native)) return mapping.result;
    return error.UnexpectedReferenceError;
}
test "pinned transaction oracle lifecycle errors lock mode and prepare event traces" {
    const parsed = try std.json.parseFromSlice(
        struct {
            library_sha256: []const u8,
            cases: []const OracleCase,
        },
        a,
        @embedFile("reference/transaction.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "da30edd45277cf4b1000485658976042f8106fe0b97378d1e6c4e81a9d7c4888",
        parsed.value.library_sha256,
    );
    for (parsed.value.cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        if (case.dependent) {
            try fixture.temporary.dir.createDirPath(io, "local/dependent-1-1");
            try fixture.temporary.dir.writeFile(
                io,
                .{
                    .sub_path = "local/dependent-1-1/desc",
                    .data = "%NAME%\ndependent\n\n%VERSION%\n1-1\n\n%DEPENDS%\ndemo\n\n",
                },
            );
        }
        var archive = try Archive.init(
            &.{
                .{
                    .path = ".PKGINFO",
                    .contents = if (case.missing)
                        "pkgname = archive\npkgver = 1-1\narch = any\ndepend = absent\n"
                    else if (case.same)
                        "pkgname = demo\npkgver = 1-1\narch = any\n"
                    else
                        "pkgname = archive\npkgver = 1-1\narch = any\n",
                },
            },
            .none,
        );
        defer archive.deinit();
        var owner = try fixture.owner(a);
        defer owner.deinit() catch unreachable;
        defer if (owner.active_transaction != null) owner.releaseTransaction() catch unreachable;
        var capture: OracleCapture = .{ .skip = case.skip };
        try owner.setCallbacks(
            .{
                .event = OracleCapture.event,
                .event_context = &capture,
                .question = OracleCapture.question,
                .question_context = &capture,
            },
        );
        for (case.trace) |expected| {
            capture.count = 0;
            const result = oracleAction(expected.action, &owner, &fixture, case, &archive);
            if (expected.@"error") |err| try std.testing.expectError(oracleError(err), result) else try result;
            try std.testing.expectEqual(expected.locked, fixture.locked());
            if (expected.locked) {
                const stat = try fixture.temporary.dir.statFile(io, "db.lck", .{});
                try std.testing.expectEqual(expected.mode.?, stat.permissions.toMode() & 0o777);
                try std.testing.expectEqual(expected.size.?, stat.size);
            }
            try std.testing.expectEqual(expected.events.len, capture.count);
            for (expected.events, capture.events[0..capture.count]) |wanted, actual|
                try std.testing.expectEqualStrings(
                    wanted,
                    actual,
                );
        }
    }
}

fn allocationTransfer(allocator: std.mem.Allocator, fixture: *Fixture, path: []const u8) !void {
    var owner = try fixture.owner(allocator);
    defer owner.deinit() catch unreachable;
    const tx = try owner.initializeTransaction(io, .{});
    defer owner.releaseTransaction() catch unreachable;
    var input: ?rlpm.Package = try owner.loadPackage(io, path, .local_file, .{});
    defer if (input) |*pkg| pkg.deinit();
    try tx.takeArchive(&input);
    try tx.prepare();
}
test "archive transfer and preparation allocation failures preserve single ownership" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var archive = try Archive.init(
        &.{
            .{ .path = ".PKGINFO", .contents = "pkgname = archive\npkgver = 1-1\n" },
        },
        .none,
    );
    defer archive.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationTransfer, .{ &fixture, archive.path });
    try std.testing.expect(!fixture.locked());
}

test "missing lock release is harmless and permission denial never creates a transaction" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    _ = try owner.initializeTransaction(io, .{});
    try fixture.temporary.dir.deleteFile(io, "db.lck");
    try owner.releaseTransaction();
    // The test runner is normally unprivileged. Root bypasses DAC permissions.
    if (std.c.geteuid() != 0) {
        const dir_file = try std.Io.Dir.cwd().openFile(io, fixture.path, .{});
        defer dir_file.close(io);
        try dir_file.setPermissions(io, .fromMode(0o500));
        defer dir_file.setPermissions(io, .fromMode(0o700)) catch unreachable;
        try std.testing.expectError(error.LockPermissionDenied, owner.initializeTransaction(io, .{}));
        try std.testing.expect(owner.transaction() == null);
        try std.testing.expect(!fixture.locked());
    }
}

test "stale state before prepare and during questions cannot become a prepared plan" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;

    const Change = struct {
        fixture: *Fixture,

        fn question(data: ?*anyopaque, q: *rlpm.Callbacks.Question) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.fixture.temporary.dir.writeFile(io, .{ .sub_path = "local/new-state", .data = "changed" }) catch
                unreachable;
            if (q.* == .remove_packages) q.remove_packages.skip = true;
        }
    };
    var change: Change = .{ .fixture = &fixture };
    try owner.setCallbacks(.{ .question = Change.question, .question_context = &change });
    var archive = try Archive.init(
        &.{
            .{
                .path = ".PKGINFO",
                .contents = "pkgname = archive\npkgver = 1-1\ndepend = absent\n",
            },
        },
        .none,
    );
    defer archive.deinit();
    var tx = try owner.initializeTransaction(io, .{});
    var input: ?rlpm.Package = try owner.loadPackage(io, archive.path, .local_file, .{});
    defer if (input) |*pkg| pkg.deinit();
    try tx.takeArchive(&input);
    try std.testing.expectError(error.StaleDatabaseState, tx.prepare());
    try owner.releaseTransaction();
    try fixture.temporary.dir.deleteFile(io, "local/new-state");
    tx = try owner.initializeTransaction(io, .{});
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "local/new-state", .data = "again" });
    try std.testing.expectError(error.StaleDatabaseState, tx.prepare());
    try owner.releaseTransaction();
}

test "transaction package references and system upgrade preserve CachyOS repository provenance" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var database_archive = try Archive.init(
        &.{
            .{
                .path = "demo-2-1/desc",
                .contents = "%NAME%\ndemo\n\n%VERSION%\n2-1\n\n%ARCH%\nany\n\n",
            },
        },
        .none,
    );
    defer database_archive.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, database_archive.path, a, .limited(1024 * 1024));
    defer a.free(bytes);
    try fixture.temporary.dir.createDirPath(io, "sync");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "sync/cachyos.db", .data = bytes });
    var owner = try fixture.owner(a);
    defer owner.deinit() catch unreachable;
    const repo = try owner.registerDatabase(.{ .database_name = "cachyos" });
    const old = (try owner.queryPackage(io, repo, "demo")).?;
    var tx = try owner.initializeTransaction(io, .{});
    try std.testing.expectError(error.StalePackageReference, tx.addPackage(old));
    const ref = (try owner.queryPackage(io, repo, "demo")).?;
    try tx.addPackage(ref);
    try tx.addPackage(ref);
    var foreign = ref;
    foreign.database.owner = @enumFromInt(@intFromEnum(ref.database.owner) + 1);
    try std.testing.expectError(error.ForeignOwner, tx.addPackage(foreign));
    const local = (try owner.findPackage(owner.localDatabase().?, "demo")).?;
    try std.testing.expectError(error.UnsupportedPackageOrigin, tx.addPackage(local));
    try std.testing.expectError(
        error.TransactionActive,
        owner.setServers(
            repo,
            .servers,
            &.{"https://example.invalid"},
        ),
    );
    try std.testing.expectError(error.TransactionActive, owner.setDatabaseUsage(repo, .{}));
    try tx.prepare();
    try std.testing.expectEqual(1, tx.plan().?.additions.len);
    try std.testing.expectEqualStrings("cachyos", tx.plan().?.additions[0].installed_database.?);
    try std.testing.expectError(error.InvalidTransactionState, tx.addPackage(ref));
    try std.testing.expectError(error.InvalidTransactionState, tx.systemUpgrade(false));
    try owner.releaseTransaction();
    tx = try owner.initializeTransaction(io, .{});
    try tx.systemUpgrade(false);
    try tx.prepare();
    try std.testing.expectEqual(.upgrade, tx.plan().?.additions[0].action);
    try std.testing.expectEqualStrings("cachyos", tx.plan().?.additions[0].installed_database.?);
    try owner.releaseTransaction();
}

test "database check output precedes initialization and supports cancellation without retaining the lock" {
    for ([_]bool{ false, true }) |cancel| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var owner = try fixture.owner(a);
        defer owner.deinit() catch unreachable;

        const Capture = struct {
            owner: *rlpm.Owner,
            cancel: bool,
            started: usize = 0,
            completed: usize = 0,
            initialized: bool = false,

            fn log(data: ?*anyopaque, value: rlpm.Callbacks.Log) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                if (std.mem.eql(u8, value.message, "Checking package databases")) {
                    self.started += 1;
                    if (self.cancel) self.owner.requestCancellation();
                }
                if (std.mem.startsWith(u8, value.message, "Package database checks complete"))
                    self.completed += 1;
            }

            fn event(data: ?*anyopaque, value: rlpm.Callbacks.Event) void {
                const self: *@This() = @ptrCast(@alignCast(data.?));
                if (value == .lifecycle and value.lifecycle.state == .initialized)
                    self.initialized = self.completed != 0;
            }
        };
        var capture: Capture = .{ .owner = &owner, .cancel = cancel };
        try owner.setCallbacks(
            .{
                .log = Capture.log,
                .log_context = &capture,
                .event = Capture.event,
                .event_context = &capture,
            },
        );
        if (cancel) {
            try std.testing.expectError(error.Cancelled, owner.initializeTransaction(io, .{}));
            try std.testing.expect(capture.started != 0 and capture.completed == 0 and !capture.initialized);
        } else {
            _ = try owner.initializeTransaction(io, .{});
            try std.testing.expect(
                capture.started != 0 and capture.started == capture.completed and
                    capture.initialized,
            );
            try owner.releaseTransaction();
        }
        try std.testing.expect(!fixture.locked());
    }
}
