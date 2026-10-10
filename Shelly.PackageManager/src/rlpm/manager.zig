//! RLPM implementation of the native package facade. No libalpm imports.
const std = @import("std");
const build_transaction = @import("../alpm/build_transaction.zig");
const os_utilities = @import("../alpm/distribution-hooks/os_utilities.zig");
const update_notice = @import("../alpm/distribution-hooks/CachyOS/update_notice.zig");
const restart_checks = @import("../alpm/restarts.zig");
const rlpm = @import("Shelly_Rlpm");
const types = @import("../alpm/types.zig");
const contract = @import("../alpm/contract.zig");
const configuration = @import("../alpm/configuration.zig");
const events = @import("../alpm/events.zig");
const op = @import("operation_context");
const Adapter = @import("rlpm_operation_adapter");
const downloader = @import("../shared/downloader.zig");
const mapping = @import("configuration.zig");
var default_family = std.atomic.Value(u8).init(@intFromEnum(downloader.AddressFamilyPolicy.prefer_ipv4));
var default_parallel = std.atomic.Value(u8).init(100);

pub const Manager = struct {
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    threaded: std.Io.Threaded,
    config: configuration.Configuration.Config,
    config_path: []const u8,
    dispatcher: events.Dispatcher,
    owner: rlpm.Owner,
    operation_context: ?*op.OperationContext,
    show_hidden_packages: bool = false,
    hooks_disabled: bool = false,
    package_setup_failed: bool = false,
    detected_cachyos: bool = false,
    temporary: bool = false,
    names: std.heap.ArenaAllocator,
    download_address_family_policy: downloader.AddressFamilyPolicy,
    parallel_download_count: u8,

    pub fn init(allocator: std.mem.Allocator, environ: std.process.Environ, options: contract.InitOptions) !*Manager {
        const self = try allocator.create(Manager);
        errdefer allocator.destroy(self);
        const owned_config_path = try allocator.dupe(u8, options.config_path orelse @import("paths").config_file);
        errdefer allocator.free(owned_config_path);
        self.* = .{
            .allocator = allocator,
            .environ = environ,
            .threaded = .init(allocator, .{ .environ = environ }),
            .config = undefined,
            .config_path = owned_config_path,
            .dispatcher = events.Dispatcher.init(allocator),
            .owner = undefined,
            .operation_context = options.operation_context,
            .names = .init(allocator),
            .download_address_family_policy = defaultDownloadAddressFamilyPolicy(),
            .parallel_download_count = defaultParallelDownloadCount(),
        };
        errdefer self.threaded.deinit();
        errdefer self.dispatcher.deinit();
        errdefer self.names.deinit();
        self.config = (if (options.config_path != null) &configuration.Configuration.parseStrict else &configuration.Configuration.parse)(allocator, self.io(), self.config_path) catch return error.ConfigParseFailed;
        errdefer self.config.deinitialize();
        if (self.config.parallel_downloads == 0) return error.ConfigParseFailed;
        try contract.applyInitPathOverrides(&self.config, options);
        if (options.temp_root_path) |path| if (path.len != 0) {
            // Preview roots copy installed metadata; never symlink a writable
            // transaction database to the host's local database.
            try mapping.preparePreview(self.io(), allocator, &self.config, path);
            self.temporary = true;
        };
        if (os_utilities.prettyName(allocator, self.io())) |name| {
            defer allocator.free(name);
            self.detected_cachyos = std.ascii.eqlIgnoreCase(name, "cachyos");
        }
        self.owner = try mapping.createOwner(self.io(), allocator, &self.config, self.parallel_download_count, options.worker_executable);
        self.owner.configuration.address_family_policy = self.download_address_family_policy;
        self.owner.configuration.callbacks = .{ .event = legacyEvent, .event_context = self };
        return self;
    }
    pub fn deinit(self: *Manager) void {
        self.owner.deinit() catch unreachable;
        self.config.deinitialize();
        self.allocator.free(self.config_path);
        self.dispatcher.deinit();
        self.names.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self);
    }
    pub fn io(self: *Manager) std.Io {
        return self.threaded.io();
    }
    pub fn setDefaultDownloadAddressFamilyPolicy(value: downloader.AddressFamilyPolicy) void {
        default_family.store(@intFromEnum(value), .release);
    }
    pub fn defaultDownloadAddressFamilyPolicy() downloader.AddressFamilyPolicy {
        return @enumFromInt(default_family.load(.acquire));
    }
    pub fn setDefaultParallelDownloadCount(value: u8) void {
        default_parallel.store(if (value == 0) 100 else value, .release);
    }
    pub fn defaultParallelDownloadCount() u8 {
        return default_parallel.load(.acquire);
    }
    pub fn setDownloadAddressFamilyPolicy(self: *Manager, value: downloader.AddressFamilyPolicy) void {
        self.download_address_family_policy = value;
        self.owner.configuration.address_family_policy = value;
    }
    pub fn setOperationContext(self: *Manager, value: ?*op.OperationContext) void {
        self.operation_context = value;
    }
    fn checkCancelled(self: *Manager) !void {
        if (self.operation_context) |context| if (context.isCancelled()) return error.Cancelled;
        try self.owner.checkCancelled();
    }
    pub fn refresh(self: *Manager) !void {
        try self.checkCancelled();
        var replacement = try mapping.createOwner(self.io(), self.allocator, &self.config, self.parallel_download_count, self.owner.configuration.worker_executable);
        errdefer replacement.deinit() catch unreachable;
        replacement.configuration.address_family_policy = self.download_address_family_policy;
        replacement.configuration.callbacks = .{ .event = legacyEvent, .event_context = self };
        try self.owner.deinit();
        self.owner = replacement;
        _ = self.names.reset(.retain_capacity);
    }
    pub fn sync(self: *Manager, force: bool) !void {
        try self.checkCancelled();
        var fallback = op.OperationContext.init(self.allocator, self.io());
        defer fallback.deinit();
        const context = self.operation_context orelse &fallback;
        const output_subscription = if (self.dispatcher.operationEvents.items.len != 0)
            try context.subscribe(.{ .function = events.Dispatcher.forwardOperationEvent, .data = &self.dispatcher })
        else
            null;
        defer if (output_subscription) |subscription| {
            _ = context.unsubscribe(subscription);
        };
        var operation = context.begin(.{ .backend = .alpm, .kind = .sync, .subject = "rlpm" });
        var status: op.CompletionStatus = .failed;
        defer operation.finish(status);
        var adapter: Adapter = undefined;
        try adapter.init(&self.owner, &operation);
        defer adapter.deinit() catch unreachable;
        var result = self.owner.refreshDatabases(self.io(), force) catch |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            try self.reportSyncFailure(&operation, self.config.database_path, err);
            return error.SyncDbFailed;
        };
        defer result.deinit();
        var failed = false;
        for (result.databases) |database| if (database.cause) |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            const name = (try self.owner.database(database.reference)).name;
            try self.reportSyncFailure(&operation, name, err);
            failed = true;
        };
        if (failed) return error.SyncDbFailed;
        status = .success;
    }
    fn reportSyncFailure(self: *Manager, operation: *op.Operation, subject: []const u8, err: anyerror) !void {
        const diagnostics = @import("diagnostics");
        const message = try std.fmt.allocPrint(self.allocator, "Could not refresh package database {f}. {s}\n\nTechnical details: {s}", .{ diagnostics.safe(subject), diagnostics.cause(err), @errorName(err) });
        defer self.allocator.free(message);
        operation.reportError(err, message, "rlpm", null, false);
        self.dispatcher.raiseError(.{ .message = message });
        if (self.operation_context == null and self.dispatcher.errorEvents.items.len == 0)
            std.log.err("{s}", .{message});
    }
    pub fn sync_for_update_check(self: *Manager, force: bool) !void {
        try self.sync(force);
    }
    pub fn get_installed_packages(self: *Manager) ![]types.OwnedPackage {
        return self.get_installed_packages_with_reverse_dependencies(.{});
    }
    pub fn get_installed_packages_with_reverse_dependencies(self: *Manager, options: types.ReverseDependencyOptions) ![]types.OwnedPackage {
        return self.collect(self.owner.localDatabase().?, options);
    }
    fn collect(self: *Manager, db: rlpm.DatabaseRef, options: types.ReverseDependencyOptions) ![]types.OwnedPackage {
        try self.checkCancelled();
        try self.owner.ensureDatabase(self.io(), db);
        var result: std.ArrayList(types.OwnedPackage) = .empty;
        errdefer {
            types.OwnedPackage.deinitItems(self.allocator, result.items);
            result.deinit(self.allocator);
        }
        for (try self.owner.packageIds(db)) |id| {
            const ref = try self.owner.packageReference(db, id);
            var value = try self.snapshot(ref, options);
            result.append(self.allocator, value) catch |err| {
                value.deinit(self.allocator);
                return err;
            };
        }
        return result.toOwnedSlice(self.allocator);
    }
    fn snapshot(self: *Manager, ref: rlpm.PackageRef, options: types.ReverseDependencyOptions) !types.OwnedPackage {
        const package = try self.owner.packageMetadata(self.io(), ref, .{});
        var result = try owned(self.allocator, package);
        errdefer result.deinit(self.allocator);
        inline for (.{ "required_by", "optional_for" }) |field| if (@field(options, field)) {
            const refs = if (comptime std.mem.eql(u8, field, "required_by")) try self.owner.requiredBy(self.io(), self.allocator, ref) else try self.owner.optionalFor(self.io(), self.allocator, ref);
            defer self.allocator.free(refs);
            const values = try self.allocator.alloc([:0]u8, refs.len);
            var count: usize = 0;
            errdefer {
                for (values[0..count]) |value| self.allocator.free(value);
                self.allocator.free(values);
            }
            for (refs, values) |r, *value| {
                value.* = try self.allocator.dupeZ(u8, (try self.owner.packageMetadata(self.io(), r, .{})).name);
                count += 1;
            }
            @field(result, field ++ "_value") = values;
        };
        return result;
    }
    pub fn get_single_installed_package(self: *Manager, name: [:0]const u8) !?types.OwnedPackage {
        try self.checkCancelled();
        const ref = try self.owner.queryPackage(self.io(), self.owner.localDatabase().?, name) orelse return null;
        return try self.snapshot(ref, .{ .required_by = true, .optional_for = true });
    }
    pub fn get_available_packages(self: *Manager) ![]types.OwnedPackage {
        var result: std.ArrayList(types.OwnedPackage) = .empty;
        errdefer {
            types.OwnedPackage.deinitItems(self.allocator, result.items);
            result.deinit(self.allocator);
        }
        for (self.owner.syncDatabases()) |db| {
            if (!db.configurationView().usage.search) continue;
            const values = try self.collect(db.identity.?, .{});
            defer self.allocator.free(values);
            result.appendSlice(self.allocator, values) catch |err| {
                types.OwnedPackage.deinitItems(self.allocator, values);
                return err;
            };
        }
        return result.toOwnedSlice(self.allocator);
    }
    pub fn get_available_packages_from_group(self: *Manager, group: [:0]const u8) ![]types.OwnedPackage {
        try self.checkCancelled();
        var result: std.ArrayList(types.OwnedPackage) = .empty;
        errdefer {
            types.OwnedPackage.deinitItems(self.allocator, result.items);
            result.deinit(self.allocator);
        }
        for (self.owner.syncDatabases()) |db| {
            if (!db.configurationView().usage.search) continue;
            const found = try self.owner.findGroup(self.io(), db.identity.?, group) orelse continue;
            for (found.packages.items) |id| {
                var value = try self.snapshot(try self.owner.packageReference(db.identity.?, id), .{});
                result.append(self.allocator, value) catch |err| {
                    value.deinit(self.allocator);
                    return err;
                };
            }
            break;
        }
        return result.toOwnedSlice(self.allocator);
    }
    pub fn get_foreign_packages(self: *Manager) ![]types.OwnedPackage {
        var result: std.ArrayList(types.OwnedPackage) = .empty;
        errdefer {
            types.OwnedPackage.deinitItems(self.allocator, result.items);
            result.deinit(self.allocator);
        }
        const installed = try self.get_installed_packages();
        defer types.OwnedPackage.deinitSlice(self.allocator, installed);
        for (installed) |pkg| {
            if (try self.owner.findCandidate(self.io(), pkg.name_value, .search) != null) continue;
            const ref = (try self.owner.findPackage(self.owner.localDatabase().?, pkg.name_value)).?;
            var value = try self.snapshot(ref, .{});
            result.append(self.allocator, value) catch |err| {
                value.deinit(self.allocator);
                return err;
            };
        }
        return result.toOwnedSlice(self.allocator);
    }
    pub fn get_updates_available(self: *Manager) ![]types.OwnedPackageWithUpdate {
        try self.checkCancelled();
        const db = self.owner.localDatabase().?;
        try self.owner.ensureDatabase(self.io(), db);
        var result: std.ArrayList(types.OwnedPackageWithUpdate) = .empty;
        errdefer {
            for (result.items) |*item| item.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        for (try self.owner.packageIds(db)) |id| {
            const ref = try self.owner.packageReference(db, id);
            const pkg = try self.owner.packageMetadata(self.io(), ref, .{});
            if (try self.upgradeFor(pkg)) |new| {
                if (!self.show_hidden_packages and try self.owner.shouldIgnore(self.io(), new)) continue;
                var old = try self.snapshot(ref, .{});
                errdefer old.deinit(self.allocator);
                var next = try self.snapshot(new, .{});
                errdefer next.deinit(self.allocator);
                try result.append(self.allocator, .{ .old_package = old, .new_package = next });
            }
        }
        return result.toOwnedSlice(self.allocator);
    }
    fn upgradeFor(self: *Manager, pkg: *const rlpm.Package) !?rlpm.PackageRef {
        for (self.owner.syncDatabases()) |db| {
            if (!db.configurationView().usage.upgrade) continue;
            const ref = self.owner.queryPackage(self.io(), db.identity.?, pkg.name) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            if (ref) |value| {
                const candidate = try self.owner.packageMetadata(self.io(), value, .{});
                return if (rlpm.Version.compareStrings(candidate.version.raw, pkg.version.raw) == .greaterThan) value else null;
            }
        }
        return null;
    }
    fn satisfies(self: *Manager, db: rlpm.DatabaseRef, dependency: rlpm.PackageRelation, literal: bool) !?rlpm.PackageRef {
        try self.checkCancelled();
        try self.owner.ensureDatabase(self.io(), db);
        for (try self.owner.packageIds(db)) |id| {
            const ref = try self.owner.packageReference(db, id);
            const pkg = try self.owner.packageMetadata(self.io(), ref, .{});
            if (literal and !std.mem.eql(u8, pkg.name, dependency.name)) continue;
            if (dependency.satisfiedBy(pkg.name, pkg.version.raw, if (literal) &.{} else pkg.provides)) return ref;
        }
        return null;
    }
    pub fn is_dependency_satisfied_by_installed_packages(self: *Manager, text: [:0]const u8) !bool {
        return (try self.satisfies(self.owner.localDatabase().?, try rlpm.PackageRelation.parse(text), false)) != null;
    }
    pub fn is_package_installed(self: *Manager, name: [:0]const u8) bool {
        return (self.owner.queryPackage(self.io(), self.owner.localDatabase().?, name) catch return false) != null;
    }
    pub fn get_package_from_provides(self: *Manager, text: [:0]const u8) ![:0]const u8 {
        const ref = try self.satisfies(self.owner.localDatabase().?, try rlpm.PackageRelation.parse(text), false) orelse return error.PkgNotFound;
        return self.names.allocator().dupeZ(u8, (try self.owner.package(ref)).name);
    }
    pub fn find_remote_satisfier_for_dependency_details(self: *Manager, text: [:0]const u8) !contract.DependencySatisfier {
        const dep = try rlpm.PackageRelation.parse(text);
        for ([_]bool{ true, false }) |literal| for (self.owner.syncDatabases()) |db| {
            if (!db.configurationView().usage.install) continue;
            if (try self.satisfies(db.identity.?, dep, literal)) |ref| {
                const pkg = try self.owner.package(ref);
                return .{ .real_name = try self.names.allocator().dupeZ(u8, pkg.name), .via_provides = !std.mem.eql(u8, dep.name, pkg.name) };
            }
        };
        return error.PkgNotFound;
    }
    pub fn find_remote_satisfier_for_dependency(self: *Manager, text: [:0]const u8) ![:0]const u8 {
        return (try self.find_remote_satisfier_for_dependency_details(text)).real_name;
    }
    pub fn get_required_packages(self: *Manager, name: []const u8, database: []const u8) ![][]const u8 {
        const db = self.owner.findDatabase(database) orelse return error.DatabaseReadFailed;
        const ref = try self.owner.queryPackage(self.io(), db, name) orelse return error.NoPackageFound;
        const refs = try self.owner.requiredBy(self.io(), self.allocator, ref);
        defer self.allocator.free(refs);
        const result = try self.allocator.alloc([]const u8, refs.len);
        var count: usize = 0;
        errdefer {
            for (result[0..count]) |v| self.allocator.free(v);
            self.allocator.free(result);
        }
        for (refs, result) |r, *value| {
            value.* = try self.allocator.dupe(u8, (try self.owner.package(r)).name);
            count += 1;
        }
        return result;
    }
    pub fn load_archive(self: *Manager, path: []const u8) !types.OwnedPackage {
        var package = try self.owner.loadPackage(self.io(), path, .local_file, .{ .mode = .full });
        defer package.deinit();
        return owned(self.allocator, &package);
    }
    const Mode = enum { install, archive, remove, upgrade };
    fn execute(self: *Manager, mode: Mode, targets: []const []const u8, flags: types.TransFlag, confirmation: contract.RemovalConfirmation) !void {
        return self.executeBuild(mode, targets, flags, confirmation, null);
    }
    fn executeBuild(self: *Manager, mode: Mode, targets: []const []const u8, flags: types.TransFlag, confirmation: contract.RemovalConfirmation, build_request: ?build_transaction.Request) anyerror!void {
        const error_generation = self.dispatcher.errorGeneration();
        // Failures before a transaction exists also need their original cause
        // delivered before the facade maps it to its compatibility error set.
        errdefer |err| if (err != error.Cancelled and self.dispatcher.errorGeneration() == error_generation) {
            const message = @import("diagnostics").format(self.allocator, err, .{ .operation = "the RLPM transaction" }) catch null;
            defer if (message) |value| self.allocator.free(value);
            self.dispatcher.raiseError(.{ .message = message orelse @errorName(err) });
        };
        if (self.temporary) return error.CommitFailed;
        try self.checkCancelled();
        var fallback = op.OperationContext.init(self.allocator, self.io());
        defer fallback.deinit();
        const context = self.operation_context orelse &fallback;
        const output_subscription = if (self.dispatcher.operationEvents.items.len != 0)
            try context.subscribe(.{ .function = events.Dispatcher.forwardOperationEvent, .data = &self.dispatcher })
        else
            null;
        defer if (output_subscription) |subscription| {
            _ = context.unsubscribe(subscription);
        };
        var operation = context.begin(.{ .backend = .alpm, .kind = switch (mode) {
            .remove => .remove,
            .upgrade => .update,
            else => .install,
        }, .subject = "rlpm" });
        defer operation.finish(.failed);
        self.dispatcher.setOperation(&operation);
        defer self.dispatcher.setOperation(null);
        var adapter: Adapter = undefined;
        try adapter.init(&self.owner, &operation);
        adapter.failure_handler = .{ .function = forwardTransactionFailure, .data = self };
        defer adapter.deinit() catch unreachable;
        var native_flags = try rlpm.TransactionFlags.fromBits(@bitCast(flags));
        native_flags.no_hooks = native_flags.no_hooks or self.hooks_disabled;
        if (flags.dbonly) native_flags.no_dependencies = true;
        const tx = try self.owner.initializeTransaction(self.io(), native_flags);
        var transaction_active = true;
        defer if (transaction_active) self.owner.releaseTransaction() catch unreachable;
        errdefer |err| operation.finish(if (err == error.Cancelled) .cancelled else .failed);
        var optional_names: std.ArrayList([]const u8) = .empty;
        defer optional_names.deinit(self.allocator);
        for (targets) |target| switch (mode) {
            .install => try tx.addTarget(target),
            .archive => {
                var package: ?rlpm.Package = try self.owner.loadPackage(self.io(), target, .local_file, .{ .mode = .full });
                defer if (package) |*p| p.deinit();
                try tx.takeArchive(&package);
            },
            .remove => try tx.remove(target),
            .upgrade => unreachable,
        };
        if (mode == .upgrade) try tx.systemUpgrade(false);
        if (mode == .install and build_request == null) try self.selectOptional(tx, targets, flags, &optional_names);
        tx.prepare() catch |err| {
            if (build_request) |request| if (request.issues) |output| {
                if (tx.plan()) |failed| {
                    var issues: std.ArrayList(build_transaction.Issue) = .empty;
                    for (failed.issues) |issue| switch (issue) {
                        .missing => |missing| try issues.append(request.allocator, .{
                            .requirement = try missing.dependency.formatAlloc(request.allocator),
                            .requiredBy = try request.allocator.dupe(u8, failed.package(missing.requiring).name),
                            .code = "unsatisfied_dependency",
                        }),
                        .target => |target| try issues.append(request.allocator, .{
                            .requirement = try request.allocator.dupe(u8, target),
                            .requiredBy = "environment",
                            .code = "not_in_repositories",
                        }),
                        .conflict => |conflict| try issues.append(request.allocator, .{
                            .requirement = try conflict.reason.formatAlloc(request.allocator),
                            .requiredBy = try request.allocator.dupe(u8, failed.package(conflict.first).name),
                            .code = "conflicting_dependencies",
                        }),
                        else => {},
                    };
                    output.* = try issues.toOwnedSlice(request.allocator);
                }
            };
            return @as(anyerror!void, err);
        };
        const plan = tx.plan() orelse {
            operation.finish(.success);
            return;
        };
        if (build_request) |request| {
            if (plan.removals.len != 0) return error.DependencyPlanMismatch;
            var snapshots: std.ArrayList(build_transaction.Package) = .empty;
            for (plan.additions) |addition| {
                const package = plan.package(addition.package);
                try snapshots.append(request.allocator, try build_transaction.fromOwned(request.allocator, try owned(request.allocator, package), package.sha256_sum));
            }
            try request.finish(try snapshots.toOwnedSlice(request.allocator));
            if (request.output != null) {
                operation.finish(.success);
                return;
            }
        }
        if (mode == .remove) for (plan.removals) |id| {
            const name = plan.package(id).name;
            for (self.config.hold_packages.items) |held| if (std.mem.eql(u8, held, name)) {
                const answer = self.dispatcher.raiseQuestion(self.io(), .{ .question = "Remove a held package?", .question_type = 0, .arguments = &.{name}, .options = &.{ "Yes", "No" } });
                if (answer.answer != 1) return error.PrepareFailed;
            };
        };
        if (self.operation_context != null and (mode != .remove or confirmation == .required)) try self.confirmPlan(&operation, plan, mode);
        if (tx.state == .prepared) {
            defer self.reportActionFailures(tx);
            try tx.commit();
        }
        self.package_setup_failed = tx.result().warnings != 0;
        // Empty/--needed plans have no commit lifecycle event. Finish before
        // releasing them so the adapter does not report a cancellation.
        operation.finish(.success);
        try self.owner.releaseTransaction();
        transaction_active = false;
        if (!flags.downloadonly) for (optional_names.items) |name| {
            const ref = try self.owner.queryPackage(self.io(), self.owner.localDatabase().?, name) orelse continue;
            try self.owner.setInstallReason(self.io(), ref, .dependency);
        };
    }
    fn forwardTransactionFailure(data: ?*anyopaque, message: []const u8) void {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.dispatcher.notifyErrorHandlers(.{ .message = message });
    }
    fn reportActionFailures(self: *Manager, tx: *const rlpm.Transaction) void {
        const actions = tx.actions() orelse return;
        for (actions.outcomes.items) |outcome| if (outcome.cause) |cause| {
            var buffer: [2048]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "Package setup {s} failed: {s}: {s}", .{ @tagName(outcome.kind), outcome.name, @errorName(cause) }) catch outcome.name;
            self.dispatcher.raiseError(.{ .message = message });
        };
    }
    fn targetReference(self: *Manager, text: []const u8) !?rlpm.PackageRef {
        if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
            const db = self.owner.findDatabase(text[0..slash]) orelse return null;
            return self.owner.queryPackage(self.io(), db, text[slash + 1 ..]);
        }
        return self.owner.findCandidate(self.io(), text, .install);
    }
    fn selectOptional(self: *Manager, tx: *rlpm.Transaction, targets: []const []const u8, flags: types.TransFlag, chosen: *std.ArrayList([]const u8)) !void {
        if (self.operation_context == null and self.dispatcher.question.items.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for (targets) |text| {
            const ref = try self.targetReference(text) orelse continue;
            const pkg = try self.owner.packageMetadata(self.io(), ref, .{});
            if (flags.needed) if (try self.owner.queryPackage(self.io(), self.owner.localDatabase().?, pkg.name)) |local| {
                if (rlpm.Version.compareStrings((try self.owner.packageMetadata(self.io(), local, .{})).version.raw, pkg.version.raw) == .equal) continue;
            };
            var names: std.ArrayList([]const u8) = .empty;
            var choices: std.ArrayList(events.ProviderOption) = .empty;
            for (pkg.optional_depends) |dep| {
                const name = try a.dupeZ(u8, dep.name);
                _ = self.find_remote_satisfier_for_dependency(name) catch |err| {
                    if (err == error.PkgNotFound) continue;
                    return err;
                };
                try names.append(a, name);
                try choices.append(a, .{ .name = name, .description = dep.description orelse "No description found", .is_installed = try self.is_dependency_satisfied_by_installed_packages(name) });
            }
            if (names.items.len == 0) continue;
            const answer = self.dispatcher.raiseQuestion(self.io(), .{ .question = try std.fmt.allocPrint(a, "Select an optional dependency for {s}", .{pkg.name}), .question_type = @intFromEnum(types.QuestionType.select_optional_dependencies), .options = names.items, .provider_options = choices.items });
            var selected: std.ArrayList([]const u8) = .empty;
            for (answer.selected_indices) |index| {
                if (index < names.items.len) try selected.append(a, names.items[index]);
            }
            if (answer.selected_indices.len == 0) if (answer.pkg) |name| {
                try selected.append(a, name);
            };
            for (selected.items) |name| {
                const name_z = try a.dupeZ(u8, name);
                if (try self.is_dependency_satisfied_by_installed_packages(name_z)) continue;
                const real = try self.find_remote_satisfier_for_dependency(name_z);
                tx.addTarget(real) catch |err| {
                    if (err == error.DuplicateTarget) continue;
                    return err;
                };
                try chosen.append(self.allocator, real);
            }
        }
    }
    fn confirmPlan(self: *Manager, operation: *op.Operation, plan: *const rlpm.TransactionPlan, mode: Mode) !void {
        var packages: std.ArrayList(op.TransactionPackage) = .empty;
        defer packages.deinit(self.allocator);
        for (plan.additions) |addition| {
            const pkg = plan.package(addition.package);
            try packages.append(self.allocator, .{ .name = pkg.name, .version = pkg.version.raw, .source = if (pkg.origin == .archive) .local else .repository, .role = if (addition.explicit_target) .requested else .dependency, .download_size = pkg.download_size orelse pkg.compressed_size, .installed_size = pkg.installed_size });
        }
        for (plan.removals) |id| {
            const pkg = plan.package(id);
            try packages.append(self.allocator, .{ .name = pkg.name, .version = pkg.version.raw, .source = .local, .role = .requested, .installed_size = pkg.installed_size });
        }
        if (packages.items.len == 0) return;
        var response = try operation.ask(.{ .kind = .confirm_transaction, .prompt = if (mode == .remove) "Proceed with package removal?" else "Proceed with package installation?", .transaction_plan = .{ .action = if (mode == .remove) .remove else if (mode == .upgrade) .update else .install, .packages = packages.items, .total_download_size = plan.sizes.download_upper_bound, .total_installed_size = if (mode == .remove) plan.sizes.installed_remove else plan.sizes.installed_add, .net_installed_size = @as(i64, @intCast(plan.sizes.installed_add)) - @as(i64, @intCast(plan.sizes.installed_remove)) }, .default_response = .accepted });
        defer response.deinit(self.allocator);
        if (response.response != .accepted) return error.Cancelled;
    }
    fn namesSlice(self: *Manager, values: []const [:0]const u8) ![][]const u8 {
        const names = try self.allocator.alloc([]const u8, values.len);
        for (values, names) |value, *name| name.* = value;
        return names;
    }
    pub fn installBuildTransaction(self: *Manager, values: [][:0]const u8, flags: types.TransFlag, request: build_transaction.Request) !void {
        const names = try self.namesSlice(values);
        defer self.allocator.free(names);
        try self.executeBuild(.install, names, flags, .already_approved, request);
    }
    pub fn install_packages(self: *Manager, values: [][:0]const u8, flags: types.TransFlag) !void {
        const names = try self.namesSlice(values);
        defer self.allocator.free(names);
        try self.execute(.install, names, flags, .already_approved);
    }
    pub fn install_local_packages(self: *Manager, paths: []const []const u8, flags: types.TransFlag) !void {
        if (paths.len == 0) return error.NoPackageFound;
        try self.execute(.archive, paths, flags, .already_approved);
    }
    pub fn remove_packages(self: *Manager, values: [][:0]const u8, flags: types.TransFlag, keep_optional: bool) !void {
        try self.remove_packages_with_confirmation(values, flags, keep_optional, .required);
    }
    pub fn remove_packages_with_confirmation(self: *Manager, values: [][:0]const u8, flags: types.TransFlag, keep_optional: bool, confirmation: contract.RemovalConfirmation) !void {
        if (values.len == 0) return error.NoPackageFound;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        const local = self.owner.localDatabase().?;
        for (values) |value| {
            if (try self.owner.queryPackage(self.io(), local, value)) |ref| {
                try appendUnique(a, &names, (try self.owner.package(ref)).name);
            } else if (try self.owner.findGroup(self.io(), local, value)) |group| {
                for (group.packages.items) |id| {
                    const ref = try self.owner.packageReference(local, id);
                    try appendUnique(a, &names, (try self.owner.packageMetadata(self.io(), ref, .{})).name);
                }
            } else {
                const ref = try self.satisfies(local, try rlpm.PackageRelation.parse(value), false) orelse return error.NoPackageFound;
                try appendUnique(a, &names, (try self.owner.package(ref)).name);
            }
        }
        const original = try a.dupe([]const u8, names.items);
        if (!keep_optional) for (original) |name| {
            const ref = (try self.owner.queryPackage(self.io(), local, name)).?;
            const pkg = try self.owner.packageMetadata(self.io(), ref, .{});
            for (pkg.optional_depends) |dep| {
                const optional = try self.satisfies(local, dep, false) orelse continue;
                const candidate = try self.owner.packageMetadata(self.io(), optional, .{});
                if (candidate.install_reason != .dependency) continue;
                const requiring = try self.owner.requiredBy(self.io(), a, optional);
                var needed = false;
                for (requiring) |required| {
                    const required_name = (try self.owner.package(required)).name;
                    var removing = false;
                    for (original) |target| {
                        if (std.mem.eql(u8, target, required_name)) removing = true;
                    }
                    if (!removing) {
                        needed = true;
                        break;
                    }
                }
                if (!needed) try appendUnique(a, &names, candidate.name);
            }
        };
        try self.execute(.remove, names.items, flags, confirmation);
    }
    fn appendUnique(a: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
        for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
        try names.append(a, try a.dupe(u8, name));
    }
    pub fn sync_system_update(self: *Manager, flags: types.TransFlag) !contract.RestartReport {
        if (self.detected_cachyos) {
            var fallback = op.OperationContext.init(self.allocator, self.io());
            defer fallback.deinit();
            var operation = (self.operation_context orelse &fallback).begin(.{ .backend = .alpm, .kind = .update, .subject = "rlpm" });
            defer operation.finish(.success);
            self.dispatcher.setOperation(&operation);
            defer self.dispatcher.setOperation(null);
            if (!update_notice.UpdateNotice.init(self.allocator, self.io()).check(self.environ, &self.dispatcher)) return contract.RestartReport.empty(self.allocator);
        }
        try self.sync(true);
        try self.execute(.upgrade, &.{}, flags, .already_approved);
        if (flags.dbonly or flags.downloadonly) return contract.RestartReport.empty(self.allocator);
        return restart_checks.check(self, .{});
    }
    pub fn update_packages(self: *Manager, values: [][:0]const u8, flags: types.TransFlag) !void {
        try self.install_packages(values, flags);
    }
    pub fn disable_transaction_hooks(self: *Manager) void {
        self.hooks_disabled = true;
    }
    pub fn update_package_reason(self: *Manager, name: [:0]const u8, reason: types.PackageReason) !void {
        const ref = try self.owner.queryPackage(self.io(), self.owner.localDatabase().?, name) orelse return error.NoPackageFound;
        try self.owner.setInstallReason(self.io(), ref, switch (reason) {
            .Explicit => .explicit,
            .Dependency => .dependency,
            .Unknown => .unknown,
        });
    }
    pub fn install_dependencies_only(self: *Manager, name: [:0]const u8, make: bool, flags: types.TransFlag) !void {
        const ref = try self.owner.findCandidate(self.io(), name, .install) orelse return error.NoPackageFound;
        const pkg = try self.owner.packageMetadata(self.io(), ref, .{});
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var names: std.ArrayList([]const u8) = .empty;
        for (pkg.depends) |dep| try names.append(arena.allocator(), try dep.formatAlloc(arena.allocator()));
        if (make) for (pkg.make_depends) |dep| {
            try names.append(arena.allocator(), try dep.formatAlloc(arena.allocator()));
        };
        if (names.items.len != 0) try self.execute(.install, names.items, flags, .already_approved);
    }
    pub fn is_cachyos(self: *const Manager) bool {
        return self.detected_cachyos;
    }
    pub fn get_allowed_architecture(self: *Manager) ![][:0]const u8 {
        const arches = self.owner.options().architectures;
        const result = try self.allocator.alloc([:0]const u8, arches.len);
        var count: usize = 0;
        errdefer {
            for (result[0..count]) |v| self.allocator.free(v);
            self.allocator.free(result);
        }
        for (arches, result) |v, *item| {
            item.* = try self.allocator.dupeZ(u8, v);
            count += 1;
        }
        return result;
    }
    pub fn ignore_package(self: *Manager, package_name: []const u8) contract.IgnorePackageError!void {
        try configuration.Configuration.add_ignore_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }
    pub fn ignore_packages(self: *Manager, package_names: []const []const u8) contract.IgnorePackageError!void {
        try configuration.Configuration.add_ignore_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }
    pub fn unignore_package(self: *Manager, package_name: []const u8) contract.IgnorePackageError!void {
        try configuration.Configuration.remove_ignore_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }
    pub fn unignore_packages(self: *Manager, package_names: []const []const u8) contract.IgnorePackageError!void {
        try configuration.Configuration.remove_ignore_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }
    pub fn get_ignored_packages(self: *Manager) contract.IgnorePackageError!std.ArrayList([:0]const u8) {
        return configuration.Configuration.get_ignored_packages(&self.config, self.allocator);
    }
    pub fn hold_package(self: *Manager, package_name: []const u8) contract.HoldPackageError!void {
        try configuration.Configuration.add_hold_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }
    pub fn hold_packages(self: *Manager, package_names: []const []const u8) contract.HoldPackageError!void {
        try configuration.Configuration.add_hold_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }
    pub fn unhold_package(self: *Manager, package_name: []const u8) contract.HoldPackageError!void {
        try configuration.Configuration.remove_hold_package(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_name,
        );
    }
    pub fn unhold_packages(self: *Manager, package_names: []const []const u8) contract.HoldPackageError!void {
        try configuration.Configuration.remove_hold_packages(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            package_names,
        );
    }
    pub fn get_held_packages(self: *Manager) contract.HoldPackageError!std.ArrayList([:0]const u8) {
        return configuration.Configuration.get_held_packages(&self.config, self.allocator);
    }
    pub fn add_repository(
        self: *Manager,
        name: []const u8,
        servers: []const []const u8,
        sig_level: []const u8,
        usage: []const u8,
    ) contract.RepositoryError!void {
        try configuration.Configuration.add_repository(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            name,
            servers,
            sig_level,
            usage,
        );
    }
    pub fn remove_repository(
        self: *Manager,
        name: []const u8,
    ) contract.RepositoryError!void {
        try configuration.Configuration.remove_repository(
            &self.config,
            self.io(),
            self.allocator,
            self.config_path,
            name,
        );
    }
    pub fn get_repository_names(self: *Manager) contract.QueryError!std.ArrayList([]const u8) {
        return configuration.Configuration.get_repository_names(&self.config, self.allocator);
    }
    pub fn find_configured_repository(
        self: *const Manager,
        name: []const u8,
    ) ?*const configuration.Configuration.Repository {
        return configuration.Configuration.find_repository(&self.config, name);
    }

    pub fn get_configured_cache_directories(self: *Manager) !std.ArrayList([:0]const u8) {
        var result: std.ArrayList([:0]const u8) = .empty;
        try result.appendSlice(self.allocator, if (self.config.cache_directories.items.len != 0) self.config.cache_directories.items else &.{self.config.cache_directory});
        return result;
    }
    pub const get_cache_directories = get_configured_cache_directories;
    pub fn purify(self: *Manager, dry_run: bool, shoot_orphans: bool, purge_corruption: bool) ![][:0]const u8 {
        var names: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (names.items) |value| self.allocator.free(value);
            names.deinit(self.allocator);
        }
        if (shoot_orphans) {
            const packages = try self.get_installed_packages_with_reverse_dependencies(.{ .required_by = true, .optional_for = true });
            defer types.OwnedPackage.deinitSlice(self.allocator, packages);
            for (packages) |pkg| if (pkg.reason_value == .Dependency and pkg.required_by_value.len == 0 and pkg.optional_for_value.len == 0) {
                const name = try self.allocator.dupeZ(u8, pkg.name_value);
                names.append(self.allocator, name) catch |err| {
                    self.allocator.free(name);
                    return err;
                };
            };
            if (!dry_run and names.items.len != 0) try self.remove_packages_with_confirmation(names.items, .{ .nosave = true, .recurse = true, .unneeded = true }, true, .already_approved);
        }
        if (purge_corruption) {
            var dir = try std.Io.Dir.cwd().openDir(self.io(), self.config.cache_directory, .{ .iterate = true });
            defer dir.close(self.io());
            var walk = try dir.walk(self.allocator);
            defer walk.deinit();
            while (try walk.next(self.io())) |entry| {
                if (entry.kind != .file or std.mem.indexOf(u8, entry.basename, ".pkg.tar") == null or std.mem.endsWith(u8, entry.basename, ".sig")) continue;
                const path = try std.fs.path.join(self.allocator, &.{ self.config.cache_directory, entry.path });
                defer self.allocator.free(path);
                if (rlpm.Package.loadArchive(self.allocator, path, .{})) |value| {
                    var package = value;
                    package.deinit();
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                    const name = try self.allocator.dupeZ(u8, entry.basename);
                    names.append(self.allocator, name) catch |append_err| {
                        self.allocator.free(name);
                        return append_err;
                    };
                    if (!dry_run) try dir.deleteFile(self.io(), entry.path);
                }
            }
        }
        return names.toOwnedSlice(self.allocator);
    }
};

fn legacyEvent(data: ?*anyopaque, event: rlpm.Callbacks.Event) void {
    const self: *Manager = @ptrCast(@alignCast(data.?));
    switch (event) {
        .scriptlet_output => |text| self.dispatcher.notifyScriptletHandlers(.{ .line = text }),
        .hook_run => |hook| if (hook.boundary == .start) {
            var buffer: [512]u8 = undefined;
            const description = @import("native_output").hookMessage(&buffer, hook.name, hook.description, hook.position, hook.total);
            self.dispatcher.notifyHookHandlers(.{ .name = hook.name, .description = description, .position = hook.position, .total = hook.total });
        },
        .diagnostic => |value| self.dispatcher.notifyErrorHandlers(.{ .message = @errorName(value.cause) }),
        else => {},
    }
}
fn owned(a: std.mem.Allocator, package: *const rlpm.Package) !types.OwnedPackage {
    var result: types.OwnedPackage = undefined;
    inline for (std.meta.fields(types.OwnedPackage)) |field| {
        @field(result, field.name) = if (field.type == [:0]u8) @constCast("") else if (field.type == [][:0]u8) &.{} else std.mem.zeroes(field.type);
    }
    errdefer result.deinit(a);
    result.name_value = try a.dupeZ(u8, package.name);
    result.base_value = try a.dupeZ(u8, package.base orelse package.name);
    result.version_value = try a.dupeZ(u8, package.version.raw);
    result.file_name_value = try a.dupeZ(u8, package.repository_filename orelse "");
    inline for (.{ "description", "url", "architecture" }) |field| if (@field(package, field)) |text| {
        @field(result, field ++ "_value") = try a.dupeZ(u8, text);
    };
    result.repository_value = try a.dupeZ(u8, if (package.origin == .local) package.installed_database orelse "local" else package.database_name);
    result.download_size_value = @intCast(package.download_size orelse package.compressed_size orelse 0);
    result.install_size_value = @intCast(package.installed_size orelse 0);
    result.build_date_value = package.build_date orelse 0;
    result.install_date_value = package.install_date;
    result.reason_value = switch (package.install_reason orelse .unknown) {
        .explicit => .Explicit,
        .dependency => .Dependency,
        .unknown => .Unknown,
    };
    inline for (.{ "replaces", "provides", "depends", "optional_depends", "conflicts", "licenses", "groups" }) |field| {
        const source = @field(package, field);
        const values = try a.alloc([:0]u8, source.len);
        var count: usize = 0;
        errdefer {
            for (values[0..count]) |v| a.free(v);
            a.free(values);
        }
        for (source, values) |item, *value| {
            if (comptime std.mem.eql(u8, field, "licenses") or std.mem.eql(u8, field, "groups")) value.* = try a.dupeZ(u8, item) else {
                const text = try item.formatAlloc(a);
                defer a.free(text);
                value.* = try a.dupeZ(u8, text);
            }
            count += 1;
        }
        @field(result, field ++ "_value") = values;
    }
    return result;
}
