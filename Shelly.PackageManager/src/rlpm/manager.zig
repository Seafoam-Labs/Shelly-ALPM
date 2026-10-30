//! RLPM implementation of the native package facade. No libalpm imports.
const std = @import("std");
const trackReturnError = @import("diagnostics").captureError;
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
var default_family = std.atomic.Value(u8).init(@backingInt(downloader.AddressFamilyPolicy.prefer_ipv4));
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
    databases_synced: bool = false,
    temporary: bool = false,
    names: std.heap.ArenaAllocator,
    download_address_family_policy: downloader.AddressFamilyPolicy,
    parallel_download_count: u8,

    pub fn init(allocator: std.mem.Allocator, environ: std.process.Environ, options: contract.InitOptions) !*Manager {
        var stage: []const u8 = "allocate manager";
        var path: ?[]const u8 = options.config_path orelse @import("paths").config_file;
        var original: ?anyerror = null;
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        return initInternal(allocator, environ, options, &stage, &path, &path_buffer, &original) catch |err| {
            reportInitializationFailure(allocator, options, original orelse err, stage, path);
            return err;
        };
    }
    pub fn reportInitializationFailure(allocator: std.mem.Allocator, options: contract.InitOptions, err: anyerror, stage: []const u8, path: ?[]const u8) void {
        if (@import("diagnostics").isCancellation(err)) return;
        const message = rlpm.Diagnostic.init(.configure, err, null).userMessage(allocator, .{ .operation = "initialization", .stage = stage, .path = path }) catch null;
        defer if (message) |value| allocator.free(value);
        var buffer: [512]u8 = undefined;
        const text = message orelse rlpm.Diagnostic.fallback(&buffer, err);
        if (options.operation_context) |context| {
            var operation = context.begin(.{ .backend = .alpm, .kind = .configure, .subject = "rlpm" });
            defer operation.finish(.failed);
            operation.reportError(err, text, "rlpm", null, false);
        } else std.debug.print("{s}\n", .{text});
    }
    fn initInternal(allocator: std.mem.Allocator, environ: std.process.Environ, options: contract.InitOptions, stage: *[]const u8, failure_path: *?[]const u8, path_buffer: []u8, original: *?anyerror) !*Manager {
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
        stage.* = "parse configuration";
        self.config = (if (options.config_path != null) &configuration.Configuration.parseStrict else &configuration.Configuration.parse)(allocator, self.io(), self.config_path) catch |err| {
            original.* = err;
            return error.ConfigParseFailed;
        };
        errdefer self.config.deinitialize();
        if (self.config.parallel_downloads == 0) {
            original.* = error.InvalidParallelDownloads;
            return error.ConfigParseFailed;
        }
        stage.* = "configure installation paths";
        try contract.applyInitPathOverrides(&self.config, options);
        if (options.temp_root_path) |path| if (path.len != 0) {
            // Preview roots copy installed metadata; never symlink a writable
            // transaction database to the host's local database.
            stage.* = "prepare update-check root";
            failure_path.* = path;
            try mapping.preparePreview(self.io(), allocator, &self.config, path);
            self.temporary = true;
        };
        if (os_utilities.prettyName(allocator, self.io())) |name| {
            defer allocator.free(name);
            self.detected_cachyos = std.ascii.eqlIgnoreCase(name, "cachyos");
        }
        stage.* = "open package databases";
        failure_path.* = std.fmt.bufPrint(path_buffer, "{s}", .{self.config.database_path}) catch options.database_path;
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
        default_family.store(@backingInt(value), .release);
    }
    pub fn defaultDownloadAddressFamilyPolicy() downloader.AddressFamilyPolicy {
        return @fromBackingInt(@intCast(default_family.load(.acquire)));
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
        const descriptor: op.OperationDescriptor = .{ .backend = .alpm, .kind = .sync, .subject = "rlpm" };
        var operation = if (self.dispatcher.operation) |parent| parent.child(descriptor) else context.begin(descriptor);
        var status: op.CompletionStatus = .failed;
        defer operation.finish(status);
        var adapter: Adapter = undefined;
        try adapter.init(&self.owner, &operation);
        adapter.failure_handler = .{ .function = forwardTransactionFailure, .data = self };
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
        self.databases_synced = true;
        status = .success;
    }
    fn reportSyncFailure(self: *Manager, operation: *op.Operation, subject: []const u8, err: anyerror) !void {
        const description = std.fmt.allocPrint(self.allocator, "refresh package database \"{s}\"", .{subject}) catch null;
        defer if (description) |value| self.allocator.free(value);
        const message = rlpm.Diagnostic.init(.refresh, err, null).userMessage(self.allocator, .{ .operation = description orelse "package database refresh", .path = self.config.database_path }) catch null;
        defer if (message) |value| self.allocator.free(value);
        var buffer: [512]u8 = undefined;
        const text = message orelse rlpm.Diagnostic.fallback(&buffer, err);
        operation.reportError(err, text, "rlpm", null, false);
        self.dispatcher.notifyErrorHandlers(.{ .message = text });
        if (self.operation_context == null and self.dispatcher.errorEvents.items.len == 0 and self.dispatcher.operationEvents.items.len == 0)
            std.debug.print("{s}\n", .{text});
    }

    /// Called before compatibility return codes replace the original RLPM cause.
    pub fn reportFailureSince(self: *Manager, err: anyerror, generation: usize, context: rlpm.Diagnostic.Context) void {
        if (@import("diagnostics").isCancellation(err) or self.dispatcher.errorGeneration() != generation) return;
        var diagnostic = rlpm.Diagnostic.init(.query, err, null);
        if (self.owner.diagnostic()) |value| if (value.cause == err) {
            diagnostic = value;
        };
        self.reportFailure(diagnostic, context);
    }
    fn reportFailure(self: *Manager, diagnostic: rlpm.Diagnostic, context: rlpm.Diagnostic.Context) void {
        const message = diagnostic.userMessage(self.allocator, context) catch null;
        defer if (message) |value| self.allocator.free(value);
        var buffer: [512]u8 = undefined;
        self.publishFailure(diagnostic.cause, message orelse rlpm.Diagnostic.fallback(&buffer, diagnostic.cause));
    }
    fn publishFailure(self: *Manager, err: anyerror, message: []const u8) void {
        if (self.dispatcher.operation) |operation| {
            operation.reportError(err, message, "rlpm", null, self.dispatcher.recoverableErrorContext() != null);
        } else {
            var fallback = op.OperationContext.init(self.allocator, self.io());
            defer fallback.deinit();
            const context = self.operation_context orelse &fallback;
            const subscription = if (self.dispatcher.operationEvents.items.len != 0)
                context.subscribe(.{ .function = events.Dispatcher.forwardOperationEvent, .data = &self.dispatcher }) catch null
            else
                null;
            defer if (subscription) |id| {
                _ = context.unsubscribe(id);
            };
            var operation = context.begin(.{ .backend = .alpm, .kind = .inspect, .subject = "rlpm" });
            defer operation.finish(.failed);
            operation.reportError(err, message, "rlpm", null, self.dispatcher.recoverableErrorContext() != null);
            if (self.operation_context == null and self.dispatcher.errorEvents.items.len == 0 and self.dispatcher.operationEvents.items.len == 0)
                std.debug.print("{s}\n", .{message});
        }
        self.dispatcher.notifyErrorHandlers(.{ .message = message });
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
                value.* = try self.allocator.dupeSentinel(u8, (try self.owner.packageMetadata(self.io(), r, .{})).name, 0);
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
        const previous_callbacks = self.owner.configuration.callbacks;
        self.owner.configuration.callbacks.question = previewUpgradeQuestion;
        self.owner.configuration.callbacks.question_with_error = null;
        defer self.owner.configuration.callbacks = previous_callbacks;
        var plan = try self.owner.resolve(self.io(), .{
            .system_upgrade = true,
            .flags = .{ .no_dependencies = true, .no_conflicts = true },
        });
        defer plan.deinit();
        if (plan.failure != null) return error.UpdateFetchFailed;
        var result: std.ArrayList(types.OwnedPackageWithUpdate) = .empty;
        errdefer {
            for (result.items) |*item| item.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        for (plan.questions) |question| {
            if (question != .replace or !question.replace.replace) continue;
            const old = plan.findReference(question.replace.old) orelse return error.UpdateFetchFailed;
            const next = plan.findReference(question.replace.new) orelse return error.UpdateFetchFailed;
            // An affirmative answer can still lose to another repository's package.
            const selected = for (plan.additions) |addition| {
                if (addition.package == next) break true;
            } else false;
            if (!selected) continue;
            try self.appendPreviewUpdate(&result, plan.package(old), plan.package(next));
        }
        for (plan.additions) |addition| {
            if (addition.old) |old|
                try self.appendPreviewUpdate(&result, plan.package(old), plan.package(addition.package));
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn previewUpgradeQuestion(_: ?*anyopaque, question: *rlpm.Callbacks.Question) void {
        if (question.* == .replace) question.replace.replace = true;
    }

    fn appendPreviewUpdate(self: *Manager, result: *std.ArrayList(types.OwnedPackageWithUpdate), old: *const rlpm.Package, next: *const rlpm.Package) !void {
        for (result.items) |update| {
            if (std.mem.eql(u8, update.old_package.name_value, old.name) and
                std.mem.eql(u8, update.new_package.name_value, next.name)) return;
        }
        var previous = try owned(self.allocator, old);
        errdefer previous.deinit(self.allocator);
        var replacement = try owned(self.allocator, next);
        errdefer replacement.deinit(self.allocator);
        try result.append(self.allocator, .{ .old_package = previous, .new_package = replacement });
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
        return self.names.allocator().dupeSentinel(u8, (try self.owner.package(ref)).name, 0);
    }
    pub fn find_remote_satisfier_for_dependency_details(self: *Manager, text: [:0]const u8) !contract.DependencySatisfier {
        const dep = try rlpm.PackageRelation.parse(text);
        for ([_]bool{ true, false }) |literal| for (self.owner.syncDatabases()) |db| {
            if (!db.configurationView().usage.install) continue;
            if (try self.satisfies(db.identity.?, dep, literal)) |ref| {
                const pkg = try self.owner.package(ref);
                return .{ .real_name = try self.names.allocator().dupeSentinel(u8, pkg.name, 0), .via_provides = !std.mem.eql(u8, dep.name, pkg.name) };
            }
        };
        return error.PkgNotFound;
    }
    pub fn find_remote_satisfier_for_dependency(self: *Manager, text: [:0]const u8) ![:0]const u8 {
        return (try self.find_remote_satisfier_for_dependency_details(text)).real_name;
    }
    pub fn get_required_packages(self: *Manager, name: []const u8, database: []const u8) ![][]const u8 {
        const db = self.owner.findDatabase(database) orelse {
            const description = std.fmt.allocPrint(self.allocator, "query required packages in repository \"{s}\"", .{database}) catch null;
            defer if (description) |value| self.allocator.free(value);
            self.reportFailure(rlpm.Diagnostic.init(.query, error.DatabaseNotFound, null), .{ .operation = description orelse "required-package lookup", .subject = name });
            return error.DatabaseReadFailed;
        };
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
        var returned_error: ?anyerror = null;
        const error_generation = self.dispatcher.errorGeneration();
        var stage: []const u8 = "initialize transaction";
        // Failures before a transaction exists also need their original cause
        // delivered before the facade maps it to its compatibility error set.
        errdefer {
            const err = returned_error.?;
            if (err != error.Cancelled and self.dispatcher.errorGeneration() == error_generation) {
                self.reportFailure(rlpm.Diagnostic.init(.transaction, err, null), .{ .operation = "the package transaction", .stage = stage, .subject = if (targets.len == 1) targets[0] else null, .path = self.config.root_directory });
            }
        }
        if (self.temporary) return trackReturnError(error.PreviewRootReadOnly, &returned_error);
        try trackReturnError(self.checkCancelled(), &returned_error);
        var fallback = op.OperationContext.init(self.allocator, self.io());
        defer fallback.deinit();
        const context = self.operation_context orelse &fallback;
        const output_subscription = if (self.dispatcher.operationEvents.items.len != 0)
            try trackReturnError(context.subscribe(.{ .function = events.Dispatcher.forwardOperationEvent, .data = &self.dispatcher }), &returned_error)
        else
            null;
        defer if (output_subscription) |subscription| {
            _ = context.unsubscribe(subscription);
        };
        const descriptor: op.OperationDescriptor = .{ .backend = .alpm, .kind = switch (mode) {
            .remove => .remove,
            .upgrade => .update,
            else => .install,
        }, .subject = "rlpm" };
        const previous_operation = self.dispatcher.operation;
        var operation = if (previous_operation) |parent| parent.child(descriptor) else context.begin(descriptor);
        defer operation.finish(.failed);
        self.dispatcher.setOperation(&operation);
        defer self.dispatcher.setOperation(previous_operation);
        errdefer {
            const err = returned_error.?;
            self.reportFailureSince(err, error_generation, .{ .operation = "the package transaction", .stage = stage, .subject = if (targets.len == 1) targets[0] else null, .path = self.config.root_directory });
            operation.finish(if (err == error.Cancelled) .cancelled else .failed);
        }
        var adapter: Adapter = undefined;
        try trackReturnError(adapter.init(&self.owner, &operation), &returned_error);
        adapter.failure_handler = .{ .function = forwardTransactionFailure, .data = self };
        defer adapter.deinit() catch unreachable;
        var native_flags = try trackReturnError(rlpm.TransactionFlags.fromBits(@bitCast(flags)), &returned_error);
        native_flags.no_hooks = native_flags.no_hooks or self.hooks_disabled;
        if (flags.dbonly) native_flags.no_dependencies = true;
        const tx = self.owner.initializeTransaction(self.io(), native_flags) catch |err| {
            // Publish before deferred cleanup detaches the operation. The facade
            // reduces lock errors to TransInitFailed, losing their context.
            if (err != error.Cancelled and self.dispatcher.errorGeneration() == error_generation) {
                const diagnostics = @import("diagnostics");
                const message = (if (err == error.DatabaseLocked or err == error.LockExists)
                    diagnostics.databaseLocked(self.allocator, self.owner.options().database_path)
                else
                    rlpm.Diagnostic.init(.transaction, err, null).userMessage(self.allocator, .{ .operation = "the package transaction", .stage = stage, .path = self.config.database_path })) catch null;
                defer if (message) |value| self.allocator.free(value);
                var buffer: [512]u8 = undefined;
                self.publishFailure(err, message orelse rlpm.Diagnostic.fallback(&buffer, err));
            }
            return trackReturnError(@as(anyerror!void, err), &returned_error);
        };
        var transaction_active = true;
        defer if (transaction_active) self.owner.releaseTransaction() catch unreachable;
        errdefer {
            const err = returned_error.?;
            self.reportFailureSince(err, error_generation, .{ .operation = "the package transaction", .stage = stage, .subject = if (targets.len == 1) targets[0] else null, .path = self.config.root_directory });
            operation.finish(if (err == error.Cancelled) .cancelled else .failed);
        }
        var optional_names: std.ArrayList([]const u8) = .empty;
        defer optional_names.deinit(self.allocator);
        for (targets) |target| switch (mode) {
            .install, .upgrade => try trackReturnError(tx.addTarget(target), &returned_error),
            .archive => {
                var package: ?rlpm.Package = try trackReturnError(self.owner.loadPackage(self.io(), target, .local_file, .{ .mode = .full }), &returned_error);
                defer if (package) |*p| p.deinit();
                try trackReturnError(tx.takeArchive(&package), &returned_error);
            },
            .remove => try trackReturnError(tx.remove(target), &returned_error),
        };
        if (mode == .upgrade) try trackReturnError(tx.systemUpgrade(false), &returned_error);
        if ((mode == .install or mode == .upgrade) and build_request == null) try trackReturnError(self.selectOptional(tx, targets, flags, &optional_names), &returned_error);
        stage = "resolve package transaction";
        tx.prepare() catch |err| {
            if (build_request) |request| if (request.issues) |output| {
                if (tx.plan()) |failed| {
                    var issues: std.ArrayList(build_transaction.Issue) = .empty;
                    for (failed.issues) |issue| switch (issue) {
                        .missing => |missing| try trackReturnError(issues.append(request.allocator, .{
                            .requirement = try trackReturnError(missing.dependency.formatAlloc(request.allocator), &returned_error),
                            .requiredBy = try trackReturnError(request.allocator.dupe(u8, failed.package(missing.requiring).name), &returned_error),
                            .code = "unsatisfied_dependency",
                        }), &returned_error),
                        .target => |target| try trackReturnError(issues.append(request.allocator, .{
                            .requirement = try trackReturnError(request.allocator.dupe(u8, target), &returned_error),
                            .requiredBy = "environment",
                            .code = "not_in_repositories",
                        }), &returned_error),
                        .conflict => |conflict| try trackReturnError(issues.append(request.allocator, .{
                            .requirement = try trackReturnError(conflict.reason.formatAlloc(request.allocator), &returned_error),
                            .requiredBy = try trackReturnError(request.allocator.dupe(u8, failed.package(conflict.first).name), &returned_error),
                            .code = "conflicting_dependencies",
                        }), &returned_error),
                        else => {},
                    };
                    output.* = try trackReturnError(issues.toOwnedSlice(request.allocator), &returned_error);
                }
            };
            return trackReturnError(@as(anyerror!void, err), &returned_error);
        };
        const plan = tx.plan() orelse {
            operation.finish(.success);
            return;
        };
        if (build_request) |request| {
            if (plan.removals.len != 0) {
                var details: std.Io.Writer.Allocating = .init(self.allocator);
                defer details.deinit();
                try trackReturnError(details.writer.writeAll("Installing the build dependencies would remove installed packages. Review these removals before changing the build environment."), &returned_error);
                for (plan.removals) |id| try trackReturnError(details.writer.print("\nWould remove: {f}", .{@import("diagnostics").safe(plan.package(id).name)}), &returned_error);
                self.reportFailure(rlpm.Diagnostic.init(.resolve, error.DependencyPlanMismatch, null), .{ .detail = details.written() });
                return trackReturnError(error.DependencyPlanMismatch, &returned_error);
            }
            var snapshots: std.ArrayList(build_transaction.Package) = .empty;
            for (plan.additions) |addition| {
                const package = plan.package(addition.package);
                try trackReturnError(snapshots.append(request.allocator, try trackReturnError(build_transaction.fromOwned(request.allocator, try trackReturnError(owned(request.allocator, package), &returned_error), package.sha256_sum), &returned_error)), &returned_error);
            }
            try trackReturnError(request.finish(try trackReturnError(snapshots.toOwnedSlice(request.allocator), &returned_error)), &returned_error);
            if (request.output != null) {
                operation.finish(.success);
                return;
            }
        }
        if (mode == .remove) for (plan.removals) |id| {
            const name = plan.package(id).name;
            for (self.config.hold_packages.items) |held| if (std.mem.eql(u8, held, name)) {
                const answer = self.dispatcher.raiseQuestion(self.io(), .{ .question = "Remove a held package?", .question_type = 0, .arguments = &.{name}, .options = &.{ "Yes", "No" } });
                if (answer.answer != 1) {
                    var buffer: [512]u8 = undefined;
                    const message = std.fmt.bufPrint(&buffer, "Removal cancelled because permission to remove held package {f} was declined.", .{@import("diagnostics").safe(name)}) catch "Removal cancelled because permission to remove a held package was declined.";
                    self.dispatcher.raiseInformational(.{ .event_type = .validation_complete, .message = message, .code = "rlpm.cancelled", .package_name = name });
                    return trackReturnError(error.Cancelled, &returned_error);
                }
            };
        };
        // Archive migration metadata and ownership are available only after preflight.
        stage = "preflight package files";
        if (tx.state == .prepared and !tx.flags.download_only) try trackReturnError(tx.preflight(), &returned_error);
        if (self.operation_context != null and (mode != .remove or confirmation == .required)) try trackReturnError(self.confirmPlan(&operation, plan, mode), &returned_error);
        if (tx.manifest()) |manifest| for (manifest.adoptions.items) |item| {
            const message = try trackReturnError(std.fmt.allocPrint(self.allocator, "Preserve {s}: {s} -> {s} ({s})", .{
                item.path,                       if (item.source) |id| plan.package(id).name else "unowned",
                plan.package(item.package).name, @tagName(item.origin),
            }), &returned_error);
            defer self.allocator.free(message);
            self.dispatcher.raiseInformational(.{ .event_type = .validation_complete, .message = message, .code = "migration_planned" });
        };
        if (tx.state == .prepared) {
            stage = "commit package transaction";
            try trackReturnError(tx.commit(), &returned_error);
            if (tx.execution.adoptions_planned != 0) {
                const message = try trackReturnError(std.fmt.allocPrint(self.allocator, "Preserved and adopted {d} file(s).", .{tx.execution.adoptions_committed}), &returned_error);
                defer self.allocator.free(message);
                self.dispatcher.raiseInformational(.{ .event_type = .validation_complete, .message = message, .code = "migration_committed" });
            }
        }
        self.package_setup_failed = tx.result().warnings != 0;
        // Empty/--needed plans have no commit lifecycle event. Finish before
        // releasing them so the adapter does not report a cancellation.
        operation.finish(.success);
        stage = "release transaction";
        try trackReturnError(self.owner.releaseTransaction(), &returned_error);
        transaction_active = false;
        stage = "record dependency install reasons";
        if (!flags.downloadonly) for (optional_names.items) |name| {
            const ref = try trackReturnError(self.owner.queryPackage(self.io(), self.owner.localDatabase().?, name), &returned_error) orelse continue;
            try trackReturnError(self.owner.setInstallReason(self.io(), ref, .dependency), &returned_error);
        };
    }
    fn forwardTransactionFailure(data: ?*anyopaque, message: []const u8) void {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.dispatcher.notifyErrorHandlers(.{ .message = message });
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
                const name = try a.dupeSentinel(u8, dep.name, 0);
                _ = self.find_remote_satisfier_for_dependency(name) catch |err| {
                    if (err == error.PkgNotFound) continue;
                    return err;
                };
                try names.append(a, name);
                try choices.append(a, .{ .name = name, .description = dep.description orelse "No description found", .is_installed = try self.is_dependency_satisfied_by_installed_packages(name) });
            }
            if (names.items.len == 0) continue;
            const answer = self.dispatcher.raiseQuestion(self.io(), .{ .question = try std.fmt.allocPrint(a, "Select an optional dependency for {s}", .{pkg.name}), .question_type = @backingInt(types.QuestionType.select_optional_dependencies), .options = names.items, .provider_options = choices.items });
            var selected: std.ArrayList([]const u8) = .empty;
            for (answer.selected_indices) |index| {
                if (index < names.items.len) try selected.append(a, names.items[index]);
            }
            if (answer.selected_indices.len == 0) if (answer.pkg) |name| {
                try selected.append(a, name);
            };
            for (selected.items) |name| {
                const name_z = try a.dupeSentinel(u8, name, 0);
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
        var migrations: std.ArrayList(op.TransactionMigration) = .empty;
        defer migrations.deinit(self.allocator);
        if (self.owner.transaction()) |tx| if (tx.manifest()) |manifest| {
            for (manifest.adoptions.items) |item| try migrations.append(self.allocator, .{
                .path = item.path,
                .destination = plan.package(item.package).name,
                .source = if (item.source) |id| plan.package(id).name else null,
                .origin = @tagName(item.origin),
            });
        };
        var response = try operation.ask(.{ .kind = .confirm_transaction, .prompt = if (mode == .remove) "Proceed with package removal?" else "Proceed with package installation?", .transaction_plan = .{ .action = if (mode == .remove) .remove else if (mode == .upgrade) .update else .install, .packages = packages.items, .migrations = migrations.items, .total_download_size = plan.sizes.download_upper_bound, .total_installed_size = if (mode == .remove) plan.sizes.installed_remove else plan.sizes.installed_add, .net_installed_size = @as(i64, @intCast(plan.sizes.installed_add)) - @as(i64, @intCast(plan.sizes.installed_remove)) }, .default_response = .accepted });
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
        return self.sync_system_update_with_packages(&.{}, flags);
    }
    pub fn sync_system_update_with_packages(self: *Manager, targets: [][:0]const u8, flags: types.TransFlag) !contract.RestartReport {
        if (self.detected_cachyos) {
            var fallback = op.OperationContext.init(self.allocator, self.io());
            defer fallback.deinit();
            var operation = (self.operation_context orelse &fallback).begin(.{ .backend = .alpm, .kind = .update, .subject = "rlpm" });
            defer operation.finish(.success);
            self.dispatcher.setOperation(&operation);
            defer self.dispatcher.setOperation(null);
            if (!update_notice.UpdateNotice.init(self.allocator, self.io()).check(self.environ, &self.dispatcher)) return contract.RestartReport.empty(self.allocator);
        }
        if (!self.databases_synced) try self.sync(true);
        const names = try self.namesSlice(targets);
        defer self.allocator.free(names);
        try self.execute(.upgrade, names, flags, .already_approved);
        if (flags.dbonly or flags.downloadonly or !std.mem.eql(u8, self.config.root_directory, "/"))
            return contract.RestartReport.empty(self.allocator);
        return restart_checks.check(self, .{});
    }
    pub fn update_packages(self: *Manager, values: [][:0]const u8, flags: types.TransFlag) !void {
        try self.install_packages(values, flags);
    }
    pub fn disable_transaction_hooks(self: *Manager) void {
        self.hooks_disabled = true;
    }
    pub fn update_package_reason(self: *Manager, name: [:0]const u8, reason: types.PackageReason) !void {
        if (reason == .Unknown) {
            self.reportFailure(rlpm.Diagnostic.init(.configure, error.InvalidOption, null), .{ .subject = name, .detail = "The package install reason must be explicit or dependency; unknown cannot be stored." });
            return error.InvalidOption;
        }
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
            item.* = try self.allocator.dupeSentinel(u8, v, 0);
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
                const name = try self.allocator.dupeSentinel(u8, pkg.name_value, 0);
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
                    const name = try self.allocator.dupeSentinel(u8, entry.basename, 0);
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
        .diagnostic => |value| self.reportFailure(value, .{ .operation = "the package operation" }),
        else => {},
    }
}
fn owned(a: std.mem.Allocator, package: *const rlpm.Package) !types.OwnedPackage {
    var result: types.OwnedPackage = undefined;
    inline for (@typeInfo(types.OwnedPackage).@"struct".field_names, @typeInfo(types.OwnedPackage).@"struct".field_types) |field_name, field_type| {
        @field(result, field_name) = if (field_type == [:0]u8) @constCast("") else if (field_type == [][:0]u8) &.{} else std.mem.zeroes(field_type);
    }
    errdefer result.deinit(a);
    result.name_value = try a.dupeSentinel(u8, package.name, 0);
    result.base_value = try a.dupeSentinel(u8, package.base orelse package.name, 0);
    result.version_value = try a.dupeSentinel(u8, package.version.raw, 0);
    result.file_name_value = try a.dupeSentinel(u8, package.repository_filename orelse "", 0);
    inline for (.{ "description", "url", "architecture" }) |field| if (@field(package, field)) |text| {
        @field(result, field ++ "_value") = try a.dupeSentinel(u8, text, 0);
    };
    result.repository_value = try a.dupeSentinel(u8, if (package.origin == .local) package.installed_database orelse "local" else package.database_name, 0);
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
            if (comptime std.mem.eql(u8, field, "licenses") or std.mem.eql(u8, field, "groups")) value.* = try a.dupeSentinel(u8, item, 0) else {
                const text = try item.formatAlloc(a);
                defer a.free(text);
                value.* = try a.dupeSentinel(u8, text, 0);
            }
            count += 1;
        }
        @field(result, field ++ "_value") = values;
    }
    return result;
}
