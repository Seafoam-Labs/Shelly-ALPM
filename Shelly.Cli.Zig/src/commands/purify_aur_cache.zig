const std = @import("std");
const PackageManager = @import("PackageManager");
const runtime = @import("../runtime/context.zig");

/// One immediate cache entry. A directory authorizes removal of all its contents.
pub const RemovalPlan = struct {
    full_path: []const u8,
    directory: bool,
    dry_run: bool,

    fn deinit(self: *RemovalPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.full_path);
        self.* = undefined;
    }
};

pub fn deinitPlans(allocator: std.mem.Allocator, plans: []RemovalPlan) void {
    for (plans) |*removal| removal.deinit(allocator);
    allocator.free(plans);
}

fn validateRoot(root: []const u8) !void {
    if (!std.fs.path.isAbsolute(root)) return error.InvalidCacheRoot;
    var components = std.mem.tokenizeScalar(u8, root, '/');
    var count: usize = 0;
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return error.InvalidCacheRoot;
        count += 1;
    }
    if (count == 0) return error.InvalidCacheRoot;
}

/// Preview immediate entries without traversing build trees or following links.
/// The root itself remains available for subsequent cache writes.
pub fn plan(
    context: *runtime.RuntimeContext,
    operation_context: *PackageManager.OperationContext,
    root: []const u8,
    dry_run: bool,
) ![]RemovalPlan {
    try validateRoot(root);
    if (operation_context.isCancelled()) return error.Cancelled;
    // A trailing slash must not turn a symlink into a followed directory.
    const root_path = std.mem.trimEnd(u8, root, "/");
    var directory = std.Io.Dir.cwd().openDir(context.io, root_path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return context.allocator.alloc(RemovalPlan, 0),
        else => return err,
    };
    defer directory.close(context.io);
    var plans: std.ArrayList(RemovalPlan) = .empty;
    errdefer {
        for (plans.items) |*removal| removal.deinit(context.allocator);
        plans.deinit(context.allocator);
    }
    var iterator = directory.iterate();
    while (try iterator.next(context.io)) |entry| {
        if (operation_context.isCancelled()) return error.Cancelled;
        const kind = if (entry.kind == .unknown)
            (try directory.statFile(context.io, entry.name, .{ .follow_symlinks = false })).kind
        else
            entry.kind;
        const path = try std.fs.path.join(context.allocator, &.{ root_path, entry.name });
        errdefer context.allocator.free(path);
        try plans.append(context.allocator, .{
            .full_path = path,
            .directory = kind == .directory,
            .dry_run = dry_run,
        });
    }
    std.mem.sort(RemovalPlan, plans.items, {}, struct {
        fn lessThan(_: void, a: RemovalPlan, b: RemovalPlan) bool {
            return std.mem.lessThan(u8, a.full_path, b.full_path);
        }
    }.lessThan);
    return plans.toOwnedSlice(context.allocator);
}

pub fn execute(
    context: *runtime.RuntimeContext,
    operation_context: *PackageManager.OperationContext,
    plans: []const RemovalPlan,
) !void {
    var operation = operation_context.begin(.{ .backend = .aur, .kind = .cleanup });
    var completion: PackageManager.OperationCompletionStatus = .failed;
    defer operation.finish(completion);
    const caller = try PackageManager.user_account.caller(context.allocator, context.environ);
    defer caller.deinit(context.allocator);
    const delegate = std.c.geteuid() == 0 and caller.uid != 0;
    for (plans, 0..) |removal, index| {
        if (operation.isCancelled()) return error.Cancelled;
        if (removal.dry_run) continue;
        const root_path = std.fs.path.dirname(removal.full_path) orelse return error.InvalidCacheRoot;
        try validateRoot(root_path);
        var root = std.Io.Dir.cwd().openDir(context.io, root_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer root.close(context.io);
        // deleteTree walks relative to directory handles and never follows
        // symlinks, including a directory replaced by a link after preview.
        const name = std.fs.path.basename(removal.full_path);
        if (delegate) {
            // The subprocess opens and removes entries with the caller's rights.
            try PackageManager.user_account.caller_io.runWithCwd(context.allocator, context.io, context.environ, &.{ "/usr/bin/rm", if (removal.directory) "-rf" else "-f", "--", name }, null, .{ .dir = root });
        } else if (removal.directory) {
            try root.deleteTree(context.io, name);
        } else {
            root.deleteFile(context.io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        operation.progress(.{
            .stage = "cache-clean",
            .completed = @intCast(index + 1),
            .total = @intCast(plans.len),
            .message = "AUR cache",
        });
    }
    completion = .success;
}

test "AUR cleanup clears all cache contents and preserves the root and external symlink targets" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const removed = [_][]const u8{
        "first/PKGBUILD",
        "first/.git/config",
        "first/src/source.tar.gz",
        "first/pkg/example/usr/bin/example",
        "first/PreviousVersions/PKGBUILD.1",
        "first/example-1-1-any.pkg.tar.zst",
        "first/example-1-1-any.pkg.tar.zst.sig",
        "zoom/zoom-7.2.1.5760_orig_x86_64.pkg.tar.xz",
        "no-pkgbuild/source.zip",
        "db/sync/example.db",
        "loose-file",
        ".hidden",
    };
    for (removed) |path| {
        const sub_path = try std.fs.path.join(std.testing.allocator, &.{ "cache", path });
        defer std.testing.allocator.free(sub_path);
        try temporary.dir.createDirPath(std.testing.io, std.fs.path.dirname(sub_path).?);
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = "fixture" });
    }
    try temporary.dir.createDirPath(std.testing.io, "cache/empty");
    try temporary.dir.createDirPath(std.testing.io, "outside");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "outside/keep", .data = "preserved" });
    try temporary.dir.symLink(std.testing.io, "../outside", "cache/linked", .{ .is_directory = true });
    try temporary.dir.symLink(std.testing.io, "../../outside", "cache/first/linked", .{ .is_directory = true });
    try temporary.dir.symLink(std.testing.io, "missing", "cache/dangling", .{});
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operation_context = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operation_context.deinit();
    const root = try std.fs.path.join(tc.context.allocator, &.{ absolute_buffer[0..absolute_length], "cache" });
    const dry_plans = try plan(&tc.context, &operation_context, root, true);
    defer deinitPlans(tc.context.allocator, dry_plans);
    try std.testing.expectEqual(@as(usize, 9), dry_plans.len);
    try execute(&tc.context, &operation_context, dry_plans);
    for (dry_plans) |entry| _ = try std.Io.Dir.cwd().statFile(std.testing.io, entry.full_path, .{ .follow_symlinks = false });

    const plans = try plan(&tc.context, &operation_context, root, false);
    defer deinitPlans(tc.context.allocator, plans);
    try execute(&tc.context, &operation_context, plans);
    // Missing targets are harmless if execution is repeated.
    try execute(&tc.context, &operation_context, plans);
    var remaining = try temporary.dir.openDir(std.testing.io, "cache", .{ .iterate = true });
    defer remaining.close(std.testing.io);
    var iterator = remaining.iterate();
    try std.testing.expectEqual(null, try iterator.next(std.testing.io));
    const contents = try temporary.dir.readFileAlloc(std.testing.io, "outside/keep", tc.context.allocator, .limited(1024));
    try std.testing.expectEqualStrings("preserved", contents);
}

test "missing AUR cache is empty and cancellation stops planning" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operation_context = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operation_context.deinit();
    const missing = try std.fs.path.join(tc.context.allocator, &.{ absolute_buffer[0..absolute_length], "missing" });
    const plans = try plan(&tc.context, &operation_context, missing, false);
    defer deinitPlans(tc.context.allocator, plans);
    try std.testing.expectEqual(@as(usize, 0), plans.len);
    try temporary.dir.createDirPath(std.testing.io, "example");
    operation_context.cancel();
    try std.testing.expectError(error.Cancelled, plan(&tc.context, &operation_context, absolute_buffer[0..absolute_length], false));
}

test "AUR cleanup unlinks a checkout replaced by a symlink without following it" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    try temporary.dir.createDirPath(std.testing.io, "cache/example");
    try temporary.dir.createDirPath(std.testing.io, "outside");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "cache/example/PKGBUILD", .data = "fixture" });
    const archive = "example-1-1-any.pkg.tar.zst";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "cache/example/" ++ archive, .data = "cached" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "outside/" ++ archive, .data = "preserved" });
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operation_context = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operation_context.deinit();
    const root = try std.fs.path.join(tc.context.allocator, &.{ absolute_buffer[0..absolute_length], "cache" });
    const plans = try plan(&tc.context, &operation_context, root, false);
    defer deinitPlans(tc.context.allocator, plans);
    try std.testing.expectEqual(@as(usize, 1), plans.len);
    try temporary.dir.deleteTree(std.testing.io, "cache/example");
    try temporary.dir.symLink(std.testing.io, "../outside", "cache/example", .{ .is_directory = true });
    try execute(&tc.context, &operation_context, plans);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "cache/example", .{ .follow_symlinks = false }));
    const contents = try temporary.dir.readFileAlloc(std.testing.io, "outside/" ++ archive, tc.context.allocator, .limited(1024));
    try std.testing.expectEqualStrings("preserved", contents);
}

test "AUR cleanup removes contents added to previewed directories but preserves new top-level entries" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    try temporary.dir.createDirPath(std.testing.io, "example");
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operations = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operations.deinit();
    const plans = try plan(&tc.context, &operations, absolute_buffer[0..absolute_length], false);
    defer deinitPlans(tc.context.allocator, plans);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "example/new-source", .data = "included" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "new-entry", .data = "not previewed" });
    operations.cancel();
    try std.testing.expectError(error.Cancelled, execute(&tc.context, &operations, plans));
    _ = try temporary.dir.statFile(std.testing.io, "example/new-source", .{});
    var active = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer active.deinit();
    try execute(&tc.context, &active, plans);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "example", .{}));
    _ = try temporary.dir.statFile(std.testing.io, "new-entry", .{});
}

test "AUR cleanup rejects invalid roots and a cache root replaced by a symlink" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    try temporary.dir.createDirPath(std.testing.io, "cache");
    try temporary.dir.createDirPath(std.testing.io, "outside");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "cache/keep", .data = "cached" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "outside/keep", .data = "preserved" });
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operations = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operations.deinit();
    for ([_][]const u8{ "", "relative", "/", "///", "/tmp/..", "/tmp/." }) |invalid|
        try std.testing.expectError(error.InvalidCacheRoot, plan(&tc.context, &operations, invalid, false));
    const root = try std.fs.path.join(tc.context.allocator, &.{ absolute_buffer[0..absolute_length], "cache" });
    const plans = try plan(&tc.context, &operations, root, false);
    defer deinitPlans(tc.context.allocator, plans);
    try temporary.dir.deleteTree(std.testing.io, "cache");
    try temporary.dir.symLink(std.testing.io, "outside", "cache", .{ .is_directory = true });
    if (execute(&tc.context, &operations, plans)) |_| return error.ExpectedSymlinkRejection else |_| {}
    if (plan(&tc.context, &operations, root, false)) |unexpected| {
        deinitPlans(tc.context.allocator, unexpected);
        return error.ExpectedSymlinkRejection;
    } else |_| {}
    const trailing_root = try std.fmt.allocPrint(tc.context.allocator, "{s}/", .{root});
    if (plan(&tc.context, &operations, trailing_root, false)) |unexpected| {
        deinitPlans(tc.context.allocator, unexpected);
        return error.ExpectedSymlinkRejection;
    } else |_| {}
    const contents = try temporary.dir.readFileAlloc(std.testing.io, "outside/keep", tc.context.allocator, .limited(1024));
    try std.testing.expectEqualStrings("preserved", contents);
}

test "AUR cleanup reports permission failures without silently keeping build trees" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    try temporary.dir.createDirPath(std.testing.io, "pkg");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/source", .data = "fixture" });
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operations = PackageManager.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operations.deinit();
    const plans = try plan(&tc.context, &operations, absolute_buffer[0..absolute_length], false);
    defer deinitPlans(tc.context.allocator, plans);
    try temporary.dir.setFilePermissions(std.testing.io, "pkg", .fromMode(0), .{});
    defer temporary.dir.setFilePermissions(std.testing.io, "pkg", .fromMode(0o700), .{}) catch {};
    // A privileged test runner can read mode-000 directories, just as the CLI can.
    if (temporary.dir.openDir(std.testing.io, "pkg", .{ .iterate = true })) |opened| {
        opened.close(std.testing.io);
        return error.SkipZigTest;
    } else |_| {}
    if (execute(&tc.context, &operations, plans)) |_| return error.ExpectedPermissionFailure else |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => {},
        else => return err,
    }
}
