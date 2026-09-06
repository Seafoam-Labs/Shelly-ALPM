const std = @import("std");
const Zigalpm = @import("Zigalpm");
const runtime = @import("../runtime/context.zig");
const RemovalPlan = Zigalpm.alpm.CacheRemovalPlan;

pub fn deinitPlans(allocator: std.mem.Allocator, plans: []RemovalPlan) void {
    for (plans) |*removal| removal.deinit(allocator);
    allocator.free(plans);
}

/// Only scan package checkout roots. Build trees, sources, and other Shelly
/// caches are not package archives and must remain available after purify.
pub fn plan(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    root: []const u8,
    dry_run: bool,
) ![]RemovalPlan {
    if (!std.fs.path.isAbsolute(root)) return error.InvalidCacheRoot;
    var directory = std.Io.Dir.cwd().openDir(context.io, root, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
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
        if (entry.kind != .directory) continue;
        var checkout = try directory.openDir(context.io, entry.name, .{ .follow_symlinks = false });
        defer checkout.close(context.io);
        const pkgbuild = checkout.statFile(context.io, "PKGBUILD", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (pkgbuild.kind != .file) continue;
        const path = try std.fs.path.join(context.allocator, &.{ root, entry.name });
        defer context.allocator.free(path);
        var cleaner = Zigalpm.CacheManager.init(context.allocator, context.io, .{ .cache_directory = path });
        cleaner.setOperationContext(operation_context);
        var removal = try cleaner.plan_cache_cleanup(.{ .keep = 0, .dry_run = dry_run });
        errdefer removal.deinit(context.allocator);
        if (removal.items.len == 0) {
            removal.deinit(context.allocator);
            continue;
        }
        try plans.append(context.allocator, removal);
    }
    std.mem.sort(RemovalPlan, plans.items, {}, struct {
        fn lessThan(_: void, a: RemovalPlan, b: RemovalPlan) bool {
            return std.mem.lessThan(u8, a.cache_directory, b.cache_directory);
        }
    }.lessThan);
    return plans.toOwnedSlice(context.allocator);
}

pub fn execute(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    plans: []const RemovalPlan,
) !void {
    for (plans) |*removal| {
        if (operation_context.isCancelled()) return error.Cancelled;
        if (removal.dry_run) continue;
        const root_path = std.fs.path.dirname(removal.cache_directory) orelse return error.InvalidCacheRoot;
        var root = try std.Io.Dir.cwd().openDir(context.io, root_path, .{ .follow_symlinks = false });
        defer root.close(context.io);
        // Keep deletion relative to an open checkout handle. Replacing the root
        // or checkout with a symlink cannot redirect removal to another tree.
        var directory = try root.openDir(context.io, std.fs.path.basename(removal.cache_directory), .{ .follow_symlinks = false });
        defer directory.close(context.io);
        var operation = operation_context.begin(.{ .backend = .aur, .kind = .cleanup });
        var completion: Zigalpm.OperationCompletionStatus = .failed;
        defer operation.finish(completion);
        for (removal.items, 0..) |item, index| {
            if (operation.isCancelled()) return error.Cancelled;
            try deletePlannedFile(context.io, directory, item.package.full_path);
            if (item.signature_path) |signature| try deletePlannedFile(context.io, directory, signature);
            operation.progress(.{
                .stage = "cache-clean",
                .completed = @intCast(index + 1),
                .total = @intCast(removal.items.len),
                .message = "AUR package-cache",
            });
        }
        completion = .success;
    }
}

fn deletePlannedFile(io: std.Io, directory: std.Io.Dir, path: []const u8) !void {
    directory.deleteFile(io, std.fs.path.basename(path)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "AUR cleanup removes all planned archives and signatures but preserves checkout contents" {
    const test_support = @import("test_support.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const root = absolute_buffer[0..absolute_length];
    const preserved = [_][]const u8{
        "first/PKGBUILD",
        "first/.git/config",
        "first/src/source.tar.gz",
        "first/pkg/example/usr/bin/example",
        "first/PreviousVersions/PKGBUILD.1",
        "second/PKGBUILD",
        "unrelated/example-1-1-any.pkg.tar.zst",
    };
    const removed = [_][]const u8{
        "first/example-1-1-any.pkg.tar.zst",
        "first/example-1-1-any.pkg.tar.zst.sig",
        "first/example-2-1-any.pkg.tar.xz",
        "second/example-debug-2-1-any.pkg.tar.zst",
    };
    for (preserved ++ removed) |path| {
        try temporary.dir.createDirPath(std.testing.io, std.fs.path.dirname(path).?);
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "fixture" });
    }
    // A symlinked checkout must not duplicate or broaden the plan.
    try temporary.dir.symLink(std.testing.io, "first", "linked", .{ .is_directory = true });
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    var operation_context = Zigalpm.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operation_context.deinit();
    const dry_plans = try plan(&tc.context, &operation_context, root, true);
    defer deinitPlans(tc.context.allocator, dry_plans);
    try std.testing.expectEqual(@as(usize, 2), dry_plans.len);
    try std.testing.expectEqual(@as(usize, 2), dry_plans[0].items.len);
    try std.testing.expectEqual(@as(usize, 1), dry_plans[1].items.len);
    try execute(&tc.context, &operation_context, dry_plans);
    for (removed) |path| _ = try temporary.dir.statFile(std.testing.io, path, .{});

    const plans = try plan(&tc.context, &operation_context, root, false);
    defer deinitPlans(tc.context.allocator, plans);
    // Files created after the preview must not be swept into execution.
    const later = "first/example-3-1-any.pkg.tar.zst";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = later, .data = "new archive" });
    try execute(&tc.context, &operation_context, plans);
    for (removed) |path|
        try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, path, .{}));
    for (preserved) |path| _ = try temporary.dir.statFile(std.testing.io, path, .{});
    _ = try temporary.dir.statFile(std.testing.io, later, .{});
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
    var operation_context = Zigalpm.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operation_context.deinit();
    const missing = try std.fs.path.join(tc.context.allocator, &.{ absolute_buffer[0..absolute_length], "missing" });
    const plans = try plan(&tc.context, &operation_context, missing, false);
    defer deinitPlans(tc.context.allocator, plans);
    try std.testing.expectEqual(@as(usize, 0), plans.len);
    try temporary.dir.createDirPath(std.testing.io, "example");
    operation_context.cancel();
    try std.testing.expectError(error.Cancelled, plan(&tc.context, &operation_context, absolute_buffer[0..absolute_length], false));
}

test "AUR cleanup refuses a checkout replaced by a symlink after preview" {
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
    var operation_context = Zigalpm.OperationContext.init(tc.context.allocator, tc.context.io);
    defer operation_context.deinit();
    const root = try std.fs.path.join(tc.context.allocator, &.{ absolute_buffer[0..absolute_length], "cache" });
    const plans = try plan(&tc.context, &operation_context, root, false);
    defer deinitPlans(tc.context.allocator, plans);
    try std.testing.expectEqual(@as(usize, 1), plans.len);
    try temporary.dir.deleteTree(std.testing.io, "cache/example");
    try temporary.dir.symLink(std.testing.io, "../outside", "cache/example", .{ .is_directory = true });
    if (execute(&tc.context, &operation_context, plans)) |_| {
        return error.ExpectedSymlinkRejection;
    } else |_| {}
    const contents = try temporary.dir.readFileAlloc(std.testing.io, "outside/" ++ archive, tc.context.allocator, .limited(1024));
    try std.testing.expectEqualStrings("preserved", contents);
}
