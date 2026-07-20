const std = @import("std");
const bindings = @import("bindings.zig");
const operation_api = @import("operation_context");

const libalpm = bindings.libalpm;
const raw_libalpm = bindings.libalpm.alpm;

pub const Error = error{
    NoHandle,
    DirectoryReadFailed,
    RemovalFailed,
    InvalidPlan,
    OutOfMemory,
    Cancelled,
};

pub const InstalledFilter = enum {
    all,
    installed_only,
    uninstalled_only,
};

pub const Options = struct {
    cache_directory: []const u8 = "/var/cache/pacman/pkg",
    handle: libalpm.Handle = null,
};

pub const CleanOptions = struct {
    /// Null uses the directory configured on CacheManager.
    cache_directory: ?[]const u8 = null,
    keep: usize = 3,
    installed_filter: InstalledFilter = .all,
    targets: []const []const u8 = &.{},
    dry_run: bool = false,
};

pub const Entry = struct {
    name: [:0]u8,
    version: [:0]u8,
    release: [:0]u8,
    version_release: [:0]u8,
    arch: [:0]u8,
    full_path: []u8,
    file_size: u64,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.release);
        allocator.free(self.version_release);
        allocator.free(self.arch);
        allocator.free(self.full_path);
        self.* = undefined;
    }

    fn clone(self: Entry, allocator: std.mem.Allocator) !Entry {
        const name = try allocator.dupeZ(u8, self.name);
        errdefer allocator.free(name);
        const version = try allocator.dupeZ(u8, self.version);
        errdefer allocator.free(version);
        const release = try allocator.dupeZ(u8, self.release);
        errdefer allocator.free(release);
        const version_release = try allocator.dupeZ(u8, self.version_release);
        errdefer allocator.free(version_release);
        const arch = try allocator.dupeZ(u8, self.arch);
        errdefer allocator.free(arch);
        return .{
            .name = name,
            .version = version,
            .release = release,
            .version_release = version_release,
            .arch = arch,
            .full_path = try allocator.dupe(u8, self.full_path),
            .file_size = self.file_size,
        };
    }
};

pub const RemovalItem = struct {
    package: Entry,
    signature_path: ?[]u8,
    signature_size: u64,

    pub fn deinit(self: *RemovalItem, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        if (self.signature_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// An owned description of exactly what cache execution will remove. Call
/// `deinit` after inspecting or executing it.
pub const RemovalPlan = struct {
    cache_directory: []u8,
    items: []RemovalItem,
    package_bytes: u64,
    signature_bytes: u64,
    dry_run: bool,

    pub fn totalBytes(self: RemovalPlan) u64 {
        return self.package_bytes +| self.signature_bytes;
    }

    pub fn deinit(self: *RemovalPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_directory);
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ExecutionResult = struct {
    dry_run: bool,
    packages_removed: usize = 0,
    signatures_removed: usize = 0,
    files_already_missing: usize = 0,
    bytes_removed: u64 = 0,
};

pub const CacheManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_directory: []const u8,
    handle: libalpm.Handle,
    operation_context: ?*operation_api.OperationContext = null,
    parent_operation: ?*const operation_api.Operation = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) CacheManager {
        return .{
            .allocator = allocator,
            .io = io,
            .cache_directory = options.cache_directory,
            .handle = options.handle,
        };
    }

    pub fn setHandle(self: *CacheManager, handle: libalpm.Handle) void {
        self.handle = handle;
    }

    /// Borrows a context for cache planning and deletion.
    pub fn setOperationContext(self: *CacheManager, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
    }

    pub fn setParentOperation(self: *CacheManager, parent: ?*const operation_api.Operation) void {
        self.parent_operation = parent;
        if (parent) |operation| self.operation_context = operation.context;
    }

    /// Scans the package cache and returns an owned removal plan. No files are
    /// deleted by this operation.
    pub fn plan_cache_cleanup(self: *CacheManager, options: CleanOptions) Error!RemovalPlan {
        if (options.installed_filter != .all and self.handle == null) return Error.NoHandle;
        var scope = CacheOperationScope.init(self.operation_context, self.parent_operation, .cleanup, options.cache_directory orelse self.cache_directory);
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        const plan = try buildRemovalPlan(
            self.allocator,
            self.io,
            options.cache_directory orelse self.cache_directory,
            options,
            .{ .context = self, .function = managerPackageInstalled },
            scope.operationPointer(),
        );
        scope.progress(plan.items.len, plan.items.len, "Package-cache removal plan ready");
        return plan;
    }

    /// Executes the exact paths in a previously generated plan. Dry-run plans
    /// are validated but never mutate the filesystem.
    pub fn execute_cache_removal_plan(self: *CacheManager, plan: *const RemovalPlan) Error!ExecutionResult {
        var scope = CacheOperationScope.init(self.operation_context, self.parent_operation, .cleanup, plan.cache_directory);
        defer scope.finish(.success);
        errdefer scope.fail();
        try scope.checkCancelled();
        return executeRemovalPlan(self.io, plan, scope.operationPointer());
    }

    fn isPackageInstalled(self: *CacheManager, package_name: [:0]const u8) bool {
        if (self.handle == null) return false;
        const local_db = raw_libalpm.alpm_get_localdb(self.handle);
        return raw_libalpm.alpm_db_get_pkg(local_db, package_name.ptr) != null;
    }
};

pub const Manager = CacheManager;

const InstalledLookup = struct {
    const Fn = *const fn (context: ?*anyopaque, package_name: [:0]const u8) bool;

    context: ?*anyopaque,
    function: Fn,

    fn isInstalled(self: InstalledLookup, package_name: [:0]const u8) bool {
        return self.function(self.context, package_name);
    }
};

/// Parses `{name}-{version}-{release}-{arch}.pkg.tar.*`. Package names are
/// parsed from right to left so embedded hyphens remain part of the name.
/// `file_size` is supplied by the caller to keep parsing independent of I/O.
pub fn parsePackageFilename(
    allocator: std.mem.Allocator,
    full_path: []const u8,
    file_size: u64,
) std.mem.Allocator.Error!?Entry {
    const file_name = std.fs.path.basename(full_path);
    if (std.mem.endsWith(u8, file_name, ".sig")) return null;
    const marker = ".pkg.tar";
    const marker_index = std.mem.lastIndexOf(u8, file_name, marker) orelse return null;
    const suffix = file_name[marker_index + marker.len ..];
    if (suffix.len != 0) {
        if (suffix[0] != '.' or suffix.len == 1) return null;
        for (suffix[1..]) |character| {
            if (!std.ascii.isAlphanumeric(character)) return null;
        }
    }

    const base_name = file_name[0..marker_index];
    const arch_separator = std.mem.lastIndexOfScalar(u8, base_name, '-') orelse return null;
    const arch = base_name[arch_separator + 1 ..];
    const through_release = base_name[0..arch_separator];
    const release_separator = std.mem.lastIndexOfScalar(u8, through_release, '-') orelse return null;
    const release = through_release[release_separator + 1 ..];
    const through_version = through_release[0..release_separator];
    const version_separator = std.mem.lastIndexOfScalar(u8, through_version, '-') orelse return null;
    const version = through_version[version_separator + 1 ..];
    const name = through_version[0..version_separator];
    if (name.len == 0 or version.len == 0 or release.len == 0 or arch.len == 0) return null;

    const owned_name = try allocator.dupeZ(u8, name);
    errdefer allocator.free(owned_name);
    const owned_version = try allocator.dupeZ(u8, version);
    errdefer allocator.free(owned_version);
    const owned_release = try allocator.dupeZ(u8, release);
    errdefer allocator.free(owned_release);
    const version_release = try std.fmt.allocPrintSentinel(allocator, "{s}-{s}", .{ version, release }, 0);
    errdefer allocator.free(version_release);
    const owned_arch = try allocator.dupeZ(u8, arch);
    errdefer allocator.free(owned_arch);
    return .{
        .name = owned_name,
        .version = owned_version,
        .release = owned_release,
        .version_release = version_release,
        .arch = owned_arch,
        .full_path = try allocator.dupe(u8, full_path),
        .file_size = file_size,
    };
}

fn buildRemovalPlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_directory: []const u8,
    options: CleanOptions,
    installed_lookup: InstalledLookup,
    operation: ?*const operation_api.Operation,
) Error!RemovalPlan {
    const owned_cache_directory = allocator.dupe(u8, cache_directory) catch return Error.OutOfMemory;
    errdefer allocator.free(owned_cache_directory);

    var directory = std.Io.Dir.cwd().openDir(io, cache_directory, .{ .iterate = true }) catch
        return Error.DirectoryReadFailed;
    defer directory.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    var iterator = directory.iterate();
    while (iterator.next(io) catch return Error.DirectoryReadFailed) |directory_entry| {
        if (operation) |active_operation| if (active_operation.isCancelled()) return Error.Cancelled;
        if (directory_entry.kind != .file) continue;
        const full_path = std.fs.path.join(allocator, &.{ cache_directory, directory_entry.name }) catch
            return Error.OutOfMemory;
        defer allocator.free(full_path);
        const stat = directory.statFile(io, directory_entry.name, .{}) catch
            return Error.DirectoryReadFailed;
        var parsed = (parsePackageFilename(allocator, full_path, stat.size) catch
            return Error.OutOfMemory) orelse continue;
        entries.append(allocator, parsed) catch {
            parsed.deinit(allocator);
            return Error.OutOfMemory;
        };
    }
    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    var removals: std.ArrayList(RemovalItem) = .empty;
    errdefer {
        for (removals.items) |*item| item.deinit(allocator);
        removals.deinit(allocator);
    }
    var package_bytes: u64 = 0;
    var signature_bytes: u64 = 0;
    var group_start: usize = 0;
    while (group_start < entries.items.len) {
        if (operation) |active_operation| if (active_operation.isCancelled()) return Error.Cancelled;
        var group_end = group_start + 1;
        while (group_end < entries.items.len and
            std.mem.eql(u8, entries.items[group_start].name, entries.items[group_end].name)) : (group_end += 1)
        {}
        const group_len = group_end - group_start;
        const removal_count = group_len - @min(group_len, options.keep);
        for (entries.items[group_start .. group_start + removal_count]) |entry| {
            if (!matchesTargets(entry.name, options.targets)) continue;
            const is_installed = if (options.installed_filter == .all)
                false
            else
                installed_lookup.isInstalled(entry.name);
            if (options.installed_filter == .installed_only and !is_installed) continue;
            if (options.installed_filter == .uninstalled_only and is_installed) continue;

            var package = entry.clone(allocator) catch return Error.OutOfMemory;
            var signature_path: ?[]u8 = null;
            var signature_size: u64 = 0;
            const possible_signature = std.fmt.allocPrint(allocator, "{s}.sig", .{entry.full_path}) catch {
                package.deinit(allocator);
                return Error.OutOfMemory;
            };
            const signature_stat = std.Io.Dir.cwd().statFile(io, possible_signature, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => {
                    allocator.free(possible_signature);
                    package.deinit(allocator);
                    return Error.DirectoryReadFailed;
                },
            };
            if (signature_stat) |stat| {
                signature_path = possible_signature;
                signature_size = stat.size;
            } else {
                allocator.free(possible_signature);
            }

            var removal: RemovalItem = .{
                .package = package,
                .signature_path = signature_path,
                .signature_size = signature_size,
            };
            removals.append(allocator, removal) catch {
                removal.deinit(allocator);
                return Error.OutOfMemory;
            };
            package_bytes +|= entry.file_size;
            signature_bytes +|= signature_size;
        }
        group_start = group_end;
    }

    const items = removals.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    return .{
        .cache_directory = owned_cache_directory,
        .items = items,
        .package_bytes = package_bytes,
        .signature_bytes = signature_bytes,
        .dry_run = options.dry_run,
    };
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    const name_order = std.mem.order(u8, a.name, b.name);
    if (name_order != .eq) return name_order == .lt;
    const version_order = raw_libalpm.alpm_pkg_vercmp(a.version_release.ptr, b.version_release.ptr);
    if (version_order != 0) return version_order < 0;
    const arch_order = std.mem.order(u8, a.arch, b.arch);
    if (arch_order != .eq) return arch_order == .lt;
    return std.mem.order(u8, a.full_path, b.full_path) == .lt;
}

fn matchesTargets(package_name: []const u8, targets: []const []const u8) bool {
    if (targets.len == 0) return true;
    for (targets) |target| {
        if (target.len <= package_name.len and
            std.ascii.eqlIgnoreCase(package_name[0..target.len], target)) return true;
    }
    return false;
}

fn managerPackageInstalled(context: ?*anyopaque, package_name: [:0]const u8) bool {
    const manager: *CacheManager = @ptrCast(@alignCast(context.?));
    return manager.isPackageInstalled(package_name);
}

fn validateRemovalPlan(plan: *const RemovalPlan) Error!void {
    if (plan.cache_directory.len == 0) return Error.InvalidPlan;
    for (plan.items) |item| {
        const parent = std.fs.path.dirname(item.package.full_path) orelse return Error.InvalidPlan;
        if (!pathsEqual(parent, plan.cache_directory)) return Error.InvalidPlan;
        if (item.signature_path) |signature_path| {
            if (signature_path.len != item.package.full_path.len + ".sig".len or
                !std.mem.startsWith(u8, signature_path, item.package.full_path) or
                !std.mem.endsWith(u8, signature_path, ".sig")) return Error.InvalidPlan;
        }
    }
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    const normalized_a = if (a.len > 1) std.mem.trimEnd(u8, a, "/") else a;
    const normalized_b = if (b.len > 1) std.mem.trimEnd(u8, b, "/") else b;
    return std.mem.eql(u8, normalized_a, normalized_b);
}

fn deleteFile(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn executeRemovalPlan(io: std.Io, plan: *const RemovalPlan, operation: ?*const operation_api.Operation) Error!ExecutionResult {
    try validateRemovalPlan(plan);
    if (operation) |active_operation| if (active_operation.isCancelled()) return Error.Cancelled;
    if (plan.dry_run) return .{ .dry_run = true };

    var result: ExecutionResult = .{ .dry_run = false };
    for (plan.items, 0..) |item, item_index| {
        if (operation) |active_operation| {
            if (active_operation.isCancelled()) return Error.Cancelled;
            active_operation.progress(.{
                .stage = "cache-clean",
                .completed = @intCast(item_index),
                .total = @intCast(plan.items.len),
                .percentage = if (plan.items.len == 0) 100 else @as(f64, @floatFromInt(item_index)) * 100.0 / @as(f64, @floatFromInt(plan.items.len)),
                .message = item.package.full_path,
            });
        }
        const package_removed = deleteFile(io, item.package.full_path) catch
            return Error.RemovalFailed;
        if (package_removed) {
            result.packages_removed += 1;
            result.bytes_removed +|= item.package.file_size;
        } else {
            result.files_already_missing += 1;
        }

        if (item.signature_path) |signature_path| {
            const signature_removed = deleteFile(io, signature_path) catch
                return Error.RemovalFailed;
            if (signature_removed) {
                result.signatures_removed += 1;
                result.bytes_removed +|= item.signature_size;
            } else {
                result.files_already_missing += 1;
            }
        }
    }
    if (operation) |active_operation| active_operation.progress(.{
        .stage = "cache-clean",
        .completed = @intCast(plan.items.len),
        .total = @intCast(plan.items.len),
        .percentage = 100,
        .message = "Package-cache cleanup complete",
    });
    return result;
}

const CacheOperationScope = struct {
    operation: ?operation_api.Operation = null,

    fn init(
        context: ?*operation_api.OperationContext,
        parent: ?*const operation_api.Operation,
        kind: operation_api.OperationKind,
        subject: ?[]const u8,
    ) CacheOperationScope {
        if (parent) |active_parent| return .{ .operation = active_parent.child(.{ .backend = .alpm, .kind = kind, .subject = subject }) };
        if (context) |operation_context| return .{ .operation = operation_context.begin(.{ .backend = .alpm, .kind = kind, .subject = subject }) };
        return .{};
    }

    fn operationPointer(self: *CacheOperationScope) ?*const operation_api.Operation {
        return if (self.operation) |*operation| operation else null;
    }

    fn checkCancelled(self: *const CacheOperationScope) error{Cancelled}!void {
        if (self.operation) |*operation| try operation.checkCancelled();
    }

    fn progress(self: *const CacheOperationScope, completed: usize, total: usize, message: []const u8) void {
        if (self.operation) |*operation| operation.progress(.{
            .stage = "cache-plan",
            .completed = @intCast(completed),
            .total = @intCast(total),
            .percentage = if (total == 0) 100 else @as(f64, @floatFromInt(completed)) * 100.0 / @as(f64, @floatFromInt(total)),
            .message = message,
        });
    }

    fn fail(self: *CacheOperationScope) void {
        if (self.operation) |*operation| operation.reportError(
            if (operation.isCancelled()) error.Cancelled else error.CacheOperationFailed,
            if (operation.isCancelled()) "Package-cache operation cancelled" else "Package-cache operation failed",
            "alpm-cache",
            null,
            false,
        );
        self.finish(if (self.operation) |*operation| if (operation.isCancelled()) .cancelled else .failed else .failed);
    }

    fn finish(self: *CacheOperationScope, status: operation_api.CompletionStatus) void {
        if (self.operation) |*operation| operation.finish(status);
    }
};

const testing = std.testing;

const TestInstalledPackages = struct {
    names: []const []const u8,

    fn lookup(context: ?*anyopaque, package_name: [:0]const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (self.names) |name| {
            if (std.mem.eql(u8, name, package_name)) return true;
        }
        return false;
    }
};

test "cache cleanup exposes planning and execution through CacheManager" {
    _ = CacheManager.plan_cache_cleanup;
    _ = CacheManager.execute_cache_removal_plan;
}

test "package-cache operations honor shared cancellation" {
    var context = operation_api.OperationContext.init(testing.allocator, testing.io);
    defer context.deinit();
    var manager = CacheManager.init(testing.allocator, testing.io, .{ .cache_directory = "/nonexistent" });
    manager.setOperationContext(&context);

    context.cancel();
    try testing.expectError(Error.Cancelled, manager.plan_cache_cleanup(.{}));
}

test "cache cleanup parses package filenames from right to left" {
    var entry = (try parsePackageFilename(
        testing.allocator,
        "/cache/my-hyphenated-tool-2:1.4.0-3-x86_64.pkg.tar.zst",
        42,
    )).?;
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("my-hyphenated-tool", entry.name);
    try testing.expectEqualStrings("2:1.4.0", entry.version);
    try testing.expectEqualStrings("3", entry.release);
    try testing.expectEqualStrings("2:1.4.0-3", entry.version_release);
    try testing.expectEqualStrings("x86_64", entry.arch);
    try testing.expectEqual(@as(u64, 42), entry.file_size);

    try testing.expect((try parsePackageFilename(
        testing.allocator,
        "/cache/tool-1.0-1-x86_64.pkg.tar.zst.sig",
        1,
    )) == null);
    try testing.expect((try parsePackageFilename(
        testing.allocator,
        "/cache/not-a-package.txt",
        1,
    )) == null);
}

test "cache cleanup plans retention targets installation filters and signatures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_directory = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/cache",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(cache_directory);
    try std.Io.Dir.cwd().createDirPath(testing.io, cache_directory);

    const Fixture = struct { name: []const u8, data: []const u8 };
    const fixtures = [_]Fixture{
        .{ .name = "foo-1.0-1-x86_64.pkg.tar.zst", .data = "oldest" },
        .{ .name = "foo-2.0-1-x86_64.pkg.tar.xz", .data = "older" },
        .{ .name = "foo-2.0-2-x86_64.pkg.tar.gz", .data = "newer" },
        .{ .name = "foo-10.0-1-x86_64.pkg.tar.zst", .data = "newest" },
        .{ .name = "my-tool-1.0-1-any.pkg.tar.zst", .data = "my-old" },
        .{ .name = "my-tool-2.0-1-any.pkg.tar.zst", .data = "my-new" },
        .{ .name = "README", .data = "ignore" },
    };
    for (fixtures) |fixture| {
        const path = try std.fs.path.join(testing.allocator, &.{ cache_directory, fixture.name });
        defer testing.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = fixture.data });
    }
    const oldest_path = try std.fs.path.join(testing.allocator, &.{ cache_directory, fixtures[0].name });
    defer testing.allocator.free(oldest_path);
    const oldest_signature = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{oldest_path});
    defer testing.allocator.free(oldest_signature);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = oldest_signature, .data = "signature" });

    var installed: TestInstalledPackages = .{ .names = &.{"foo"} };
    const lookup: InstalledLookup = .{ .context = &installed, .function = TestInstalledPackages.lookup };
    var dry_run_plan = try buildRemovalPlan(
        testing.allocator,
        testing.io,
        cache_directory,
        .{ .keep = 2, .targets = &.{"FO"}, .dry_run = true },
        lookup,
        null,
    );
    defer dry_run_plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), dry_run_plan.items.len);
    try testing.expectEqualStrings("1.0-1", dry_run_plan.items[0].package.version_release);
    try testing.expectEqualStrings("2.0-1", dry_run_plan.items[1].package.version_release);
    try testing.expect(dry_run_plan.items[0].signature_path != null);
    try testing.expect(dry_run_plan.package_bytes > 0);
    try testing.expect(dry_run_plan.signature_bytes > 0);
    const dry_result = try executeRemovalPlan(testing.io, &dry_run_plan, null);
    try testing.expect(dry_result.dry_run);
    try std.Io.Dir.cwd().access(testing.io, oldest_path, .{});
    try std.Io.Dir.cwd().access(testing.io, oldest_signature, .{});

    var installed_plan = try buildRemovalPlan(
        testing.allocator,
        testing.io,
        cache_directory,
        .{ .keep = 0, .installed_filter = .installed_only },
        lookup,
        null,
    );
    defer installed_plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), installed_plan.items.len);
    for (installed_plan.items) |item| try testing.expectEqualStrings("foo", item.package.name);

    var uninstalled_plan = try buildRemovalPlan(
        testing.allocator,
        testing.io,
        cache_directory,
        .{ .keep = 0, .installed_filter = .uninstalled_only, .targets = &.{"MY"} },
        lookup,
        null,
    );
    defer uninstalled_plan.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), uninstalled_plan.items.len);
    for (uninstalled_plan.items) |item| try testing.expectEqualStrings("my-tool", item.package.name);

    var removal_plan = try buildRemovalPlan(
        testing.allocator,
        testing.io,
        cache_directory,
        .{ .keep = 2, .targets = &.{"foo"} },
        lookup,
        null,
    );
    defer removal_plan.deinit(testing.allocator);
    const result = try executeRemovalPlan(testing.io, &removal_plan, null);
    try testing.expect(!result.dry_run);
    try testing.expectEqual(@as(usize, 2), result.packages_removed);
    try testing.expectEqual(@as(usize, 1), result.signatures_removed);
    try testing.expect(result.bytes_removed == removal_plan.totalBytes());
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, oldest_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, oldest_signature, .{}));
    const newest_path = try std.fs.path.join(testing.allocator, &.{ cache_directory, fixtures[3].name });
    defer testing.allocator.free(newest_path);
    try std.Io.Dir.cwd().access(testing.io, newest_path, .{});
}
