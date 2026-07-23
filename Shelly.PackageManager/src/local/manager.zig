const std = @import("std");
const archive = @import("archive.zig");
const events = @import("events.zig");
const file_inspector = @import("file_inspector.zig");
const xdg_integration = @import("xdg_integration.zig");
const operations = @import("operation_context");

pub const Error = error{
    Cancelled,
    CommandConflict,
    DuplicateCommand,
    InvalidPackageName,
    InvalidPackagePath,
    PackageTooLarge,
    TooManyArchiveEntries,
};

pub const default_install_directory = "/opt/shelly";

pub const Options = struct {
    install_directory: []const u8 = default_install_directory,
    binary_directory: []const u8 = "/usr/bin",
    desktop_directory: []const u8 = "/usr/share/applications",
    icon_root: []const u8 = "/usr/share/icons/hicolor",
    run_cache_updates: bool = true,
    max_entry_size: u64 = 512 * 1024 * 1024,
    max_total_size: u64 = 4 * 1024 * 1024 * 1024,
    max_entries: usize = 100_000,
};

pub const Package = struct {
    name: []u8,
    path: []u8,
    size: u64,

    pub fn deinit(self: *Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, packages: []Package) void {
        for (packages) |*package| package.deinit(allocator);
        allocator.free(packages);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dispatcher: events.Dispatcher,
    cancellation: ?events.Cancellation = null,
    operation_context: ?*operations.OperationContext = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dispatcher = events.Dispatcher.init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        self.dispatcher.deinit();
        self.* = undefined;
    }

    pub fn addMessageHandler(self: *Manager, handler: events.Handler) !usize {
        return self.dispatcher.add(handler);
    }

    pub fn removeMessageHandler(self: *Manager, token: usize) void {
        self.dispatcher.remove(token);
    }

    pub fn setCancellation(self: *Manager, cancellation: ?events.Cancellation) void {
        self.cancellation = cancellation;
    }

    /// Borrows a shared operation context for subsequent synchronous calls.
    pub fn setOperationContext(self: *Manager, context: ?*operations.OperationContext) void {
        self.operation_context = context;
    }

    /// Extracts a local binary archive into the configured package root and
    /// creates links and desktop integration for extensionless ELF commands.
    pub fn installBinariesPackage(self: *Manager, archive_path: []const u8) !bool {
        var scope = OperationScope.init(self, .install, archive_path);
        scope.attach();
        defer scope.finish(.success);
        return self.installBinariesPackageImpl(archive_path) catch |err| {
            self.reportError(err, @errorName(err));
            self.emitFmt(.err, "Failed to install local package: {s}", .{@errorName(err)});
            scope.finish(if (err == Error.Cancelled) .cancelled else .failed);
            return err;
        };
    }

    fn installBinariesPackageImpl(self: *Manager, archive_path: []const u8) !bool {
        try self.checkCancelled();
        if (!file_inspector.isSupportedArchive(archive_path)) {
            self.emit(.warning, "Unsupported local package archive");
            return false;
        }

        const inspector: file_inspector.Inspector = .{ .allocator = self.allocator, .io = self.io };
        self.progress("inspect", 0, 1, "Inspecting local package archive");
        if (!(try inspector.isBinariesPackage(archive_path))) {
            self.emit(.warning, "Archive does not contain an ELF binary");
            return false;
        }
        self.progress("inspect", 1, 1, "Local package archive inspected");

        const package_name = try packageName(self.allocator, archive_path);
        defer self.allocator.free(package_name);
        try std.Io.Dir.cwd().createDirPath(self.io, self.options.install_directory);

        const staging_path = try self.uniqueSiblingPath(package_name, "install");
        defer self.allocator.free(staging_path);
        std.Io.Dir.cwd().deleteTree(self.io, staging_path) catch {};
        try std.Io.Dir.cwd().createDirPath(self.io, staging_path);
        errdefer std.Io.Dir.cwd().deleteTree(self.io, staging_path) catch {};

        self.emitFmt(.information, "Extracting {s}", .{std.fs.path.basename(archive_path)});
        try self.extractArchive(archive_path, staging_path);

        var staged_assets = try self.inspectInstalledTree(staging_path, true);
        defer staged_assets.deinit(self.allocator);
        for (staged_assets.binaries.items, 0..) |binary_path, index| {
            const binary_name = std.fs.path.basename(binary_path);
            try validateCommandName(binary_name);
            for (staged_assets.binaries.items[0..index]) |previous_path| {
                if (std.mem.eql(u8, std.fs.path.basename(previous_path), binary_name))
                    return Error.DuplicateCommand;
            }
            try self.ensureLinkAvailable(binary_name);
        }

        const final_path = try std.fs.path.join(self.allocator, &.{ self.options.install_directory, package_name });
        defer self.allocator.free(final_path);
        var previous_assets: ?Assets = self.inspectInstalledTree(final_path, false) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (previous_assets) |*assets| assets.deinit(self.allocator);
        try self.commitStaging(staging_path, final_path, package_name);
        if (previous_assets) |*assets|
            self.cleanupReplacedAssets(assets, &staged_assets, package_name);

        var assets = try self.inspectInstalledTree(final_path, true);
        defer assets.deinit(self.allocator);
        try std.Io.Dir.cwd().createDirPath(self.io, self.options.binary_directory);

        const integration = self.xdg();
        for (assets.binaries.items, 0..) |binary_path, binary_index| {
            try self.checkCancelled();
            self.progress("integrate", binary_index, assets.binaries.items.len, "Integrating local commands");
            const binary_name = std.fs.path.basename(binary_path);
            const link_path = try std.fs.path.join(self.allocator, &.{ self.options.binary_directory, binary_name });
            defer self.allocator.free(link_path);
            std.Io.Dir.cwd().deleteFile(self.io, link_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try std.Io.Dir.cwd().symLink(self.io, binary_path, link_path, .{});
            self.emitFmt(.success, "Linked {s}", .{binary_name});

            if (!containsIgnoreCase(package_name, binary_name)) continue;
            var icon_name: ?[]u8 = null;
            defer if (icon_name) |name| self.allocator.free(name);
            if (assets.icon_path) |icon_path| {
                icon_name = integration.installIcon(icon_path, binary_name) catch |err| blk: {
                    self.emitFmt(.warning, "Could not install icon for {s}: {s}", .{ binary_name, @errorName(err) });
                    break :blk null;
                };
            } else {
                self.emitFmt(.warning, "No icon found for {s}", .{binary_name});
            }
            const desktop_file_name = try xdg_integration.cleanName(self.allocator, binary_name);
            defer self.allocator.free(desktop_file_name);
            integration.createDesktopEntry(.{
                .app_name = binary_name,
                .file_name = desktop_file_name,
                .executable = binary_name,
                .comment = "Installed by Shelly",
                .icon = icon_name orelse "application-x-executable",
            }) catch |err| {
                self.emitFmt(.warning, "Could not create desktop entry for {s}: {s}", .{ binary_name, @errorName(err) });
            };
        }
        self.progress("integrate", assets.binaries.items.len, assets.binaries.items.len, "Local command integration complete");

        self.emitFmt(.success, "Installed local package {s}", .{package_name});
        return true;
    }

    /// Returns owned package records for direct children of the install root.
    pub fn getInstalledBinaryPackages(self: *Manager) ![]Package {
        var scope = OperationScope.init(self, .inspect, self.options.install_directory);
        scope.attach();
        defer scope.finish(.success);
        return self.getInstalledBinaryPackagesImpl() catch |err| {
            self.reportError(err, "Failed to inspect installed local packages");
            scope.finish(if (err == Error.Cancelled) .cancelled else .failed);
            return err;
        };
    }

    fn getInstalledBinaryPackagesImpl(self: *Manager) ![]Package {
        var root = std.Io.Dir.cwd().openDir(self.io, self.options.install_directory, .{ .iterate = true }) catch |open_err| switch (open_err) {
            error.FileNotFound => return self.allocator.alloc(Package, 0),
            else => return open_err,
        };
        defer root.close(self.io);

        var packages: std.ArrayList(Package) = .empty;
        errdefer {
            for (packages.items) |*package| package.deinit(self.allocator);
            packages.deinit(self.allocator);
        }
        var iterator = root.iterate();
        while (try iterator.next(self.io)) |entry| {
            try self.checkCancelled();
            if (entry.kind != .directory or entry.name[0] == '.') continue;
            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            const path = try std.fs.path.join(self.allocator, &.{ self.options.install_directory, entry.name });
            errdefer self.allocator.free(path);
            try packages.append(self.allocator, .{
                .name = name,
                .path = path,
                .size = try directorySize(self.allocator, self.io, path),
            });
        }
        std.mem.sort(Package, packages.items, {}, packageLessThan);
        return packages.toOwnedSlice(self.allocator);
    }

    /// Removes package directories and only deletes command links which still
    /// point into the package being removed.
    pub fn removeBinaryPackages(self: *Manager, package_names_or_paths: []const []const u8) !bool {
        var scope = OperationScope.init(self, .remove, null);
        scope.attach();
        defer scope.finish(.success);
        return self.removeBinaryPackagesImpl(package_names_or_paths) catch |err| {
            self.reportError(err, @errorName(err));
            self.emitFmt(.err, "Failed to remove local package: {s}", .{@errorName(err)});
            scope.finish(if (err == Error.Cancelled) .cancelled else .failed);
            return err;
        };
    }

    fn removeBinaryPackagesImpl(self: *Manager, package_names_or_paths: []const []const u8) !bool {
        var removed_any = false;
        for (package_names_or_paths, 0..) |value, package_index| {
            try self.checkCancelled();
            self.progress("remove", package_index, package_names_or_paths.len, "Removing local packages");
            const package_path = self.resolvePackagePath(value) catch |err| {
                self.emitFmt(.warning, "Ignoring invalid local package path {s}: {s}", .{ value, @errorName(err) });
                continue;
            };
            defer self.allocator.free(package_path);

            var assets = self.inspectInstalledTree(package_path, false) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer assets.deinit(self.allocator);
            const integration = self.xdg();
            for (assets.binaries.items) |binary_path| {
                const binary_name = std.fs.path.basename(binary_path);
                const link_path = try std.fs.path.join(self.allocator, &.{ self.options.binary_directory, binary_name });
                defer self.allocator.free(link_path);
                if (!(try linkPointsTo(self.io, link_path, binary_path))) continue;
                try std.Io.Dir.cwd().deleteFile(self.io, link_path);
                if (!containsIgnoreCase(std.fs.path.basename(package_path), binary_name)) continue;
                _ = integration.removeDesktopEntry(binary_name) catch |err| {
                    self.emitFmt(.warning, "Could not remove desktop entry for {s}: {s}", .{ binary_name, @errorName(err) });
                    continue;
                };
                _ = integration.removeInstalledIcons(binary_name) catch |err| {
                    self.emitFmt(.warning, "Could not remove icons for {s}: {s}", .{ binary_name, @errorName(err) });
                    continue;
                };
            }
            try std.Io.Dir.cwd().deleteTree(self.io, package_path);
            self.emitFmt(.success, "Removed local package {s}", .{std.fs.path.basename(package_path)});
            removed_any = true;
        }
        self.progress("remove", package_names_or_paths.len, package_names_or_paths.len, "Local package removal complete");
        return removed_any;
    }

    fn extractArchive(self: *Manager, source_path: []const u8, staging_path: []const u8) !void {
        var reader = try archive.Reader.init(self.allocator, source_path);
        defer reader.deinit();
        var entry_count: usize = 0;
        var total_size: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined;

        while (try reader.next()) |entry| {
            try self.checkCancelled();
            entry_count += 1;
            self.progress("extract", entry_count, null, entry.path);
            if (entry_count > self.options.max_entries) return Error.TooManyArchiveEntries;
            if (entry.size > self.options.max_entry_size) return Error.PackageTooLarge;
            const relative_path = try archive.normalizeEntryPath(self.allocator, entry.path);
            defer self.allocator.free(relative_path);
            const destination = try std.fs.path.join(self.allocator, &.{ staging_path, relative_path });
            defer self.allocator.free(destination);

            switch (entry.kind) {
                .directory => try std.Io.Dir.cwd().createDirPath(self.io, destination),
                .regular_file => {
                    if (std.fs.path.dirname(destination)) |parent|
                        try std.Io.Dir.cwd().createDirPath(self.io, parent);
                    var output = try std.Io.Dir.cwd().createFile(self.io, destination, .{
                        .truncate = true,
                        .permissions = std.Io.File.Permissions.fromMode(safeMode(entry.permissions)),
                    });
                    defer output.close(self.io);
                    var writer = output.writer(self.io, &.{});
                    var entry_size: u64 = 0;
                    while (true) {
                        const amount = try reader.read(&buffer);
                        if (amount == 0) break;
                        entry_size += amount;
                        total_size += amount;
                        if (entry_size > self.options.max_entry_size or total_size > self.options.max_total_size)
                            return Error.PackageTooLarge;
                        try writer.interface.writeAll(buffer[0..amount]);
                    }
                },
                .symbolic_link, .other => try reader.skip(),
            }
        }
    }

    fn commitStaging(self: *Manager, staging_path: []const u8, final_path: []const u8, package_name: []const u8) !void {
        const backup_path = try self.uniqueSiblingPath(package_name, "backup");
        defer self.allocator.free(backup_path);
        std.Io.Dir.cwd().deleteTree(self.io, backup_path) catch {};

        const had_existing = blk: {
            std.Io.Dir.rename(.cwd(), final_path, .cwd(), backup_path, self.io) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        std.Io.Dir.rename(.cwd(), staging_path, .cwd(), final_path, self.io) catch |err| {
            if (had_existing) std.Io.Dir.rename(.cwd(), backup_path, .cwd(), final_path, self.io) catch {};
            return err;
        };
        if (had_existing) std.Io.Dir.cwd().deleteTree(self.io, backup_path) catch |err| {
            self.emitFmt(.warning, "Could not remove package backup: {s}", .{@errorName(err)});
        };
    }

    fn inspectInstalledTree(self: *Manager, package_path: []const u8, linkable_only: bool) !Assets {
        var directory = try std.Io.Dir.cwd().openDir(self.io, package_path, .{ .iterate = true });
        defer directory.close(self.io);
        var walker = try directory.walk(self.allocator);
        defer walker.deinit();
        var assets: Assets = .{};
        errdefer assets.deinit(self.allocator);
        const inspector: file_inspector.Inspector = .{ .allocator = self.allocator, .io = self.io };

        while (try walker.next(self.io)) |entry| {
            try self.checkCancelled();
            if (entry.kind != .file) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ package_path, entry.path });
            if (try inspector.isElfFile(full_path)) {
                if (!linkable_only or std.fs.path.extension(entry.basename).len == 0) {
                    try assets.binaries.append(self.allocator, full_path);
                } else {
                    self.allocator.free(full_path);
                }
                continue;
            }
            if (file_inspector.isIcon(entry.basename)) {
                if (assets.icon_path == null or std.mem.order(u8, full_path, assets.icon_path.?) == .lt) {
                    if (assets.icon_path) |old| self.allocator.free(old);
                    assets.icon_path = full_path;
                } else {
                    self.allocator.free(full_path);
                }
            } else {
                self.allocator.free(full_path);
            }
        }
        std.mem.sort([]u8, assets.binaries.items, {}, stringLessThan);
        return assets;
    }

    fn resolvePackagePath(self: *Manager, value: []const u8) ![]u8 {
        if (value.len == 0 or std.mem.indexOfAny(u8, value, "\\\r\n") != null)
            return Error.InvalidPackagePath;
        if (std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, '/') != null) {
            const parent = std.fs.path.dirname(value) orelse return Error.InvalidPackagePath;
            if (!pathsEqual(parent, std.mem.trimEnd(u8, self.options.install_directory, "/")))
                return Error.InvalidPackagePath;
            try validatePackageName(std.fs.path.basename(value));
            return self.allocator.dupe(u8, value);
        }
        try validatePackageName(value);
        return std.fs.path.join(self.allocator, &.{ self.options.install_directory, value });
    }

    fn uniqueSiblingPath(self: *Manager, package_name: []const u8, kind: []const u8) ![]u8 {
        var random: [8]u8 = undefined;
        self.io.random(&random);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/.{s}.{s}-{s}",
            .{ self.options.install_directory, package_name, kind, std.fmt.bytesToHex(random, .lower) },
        );
    }

    fn ensureLinkAvailable(self: *Manager, binary_name: []const u8) !void {
        const link_path = try std.fs.path.join(self.allocator, &.{ self.options.binary_directory, binary_name });
        defer self.allocator.free(link_path);
        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const amount = std.Io.Dir.cwd().readLink(self.io, link_path, &target_buffer) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotLink => return Error.CommandConflict,
            else => return err,
        };
        if (!pathIsWithin(target_buffer[0..amount], self.options.install_directory))
            return Error.CommandConflict;
    }

    fn cleanupReplacedAssets(
        self: *Manager,
        previous_assets: *const Assets,
        replacement_assets: *const Assets,
        package_name: []const u8,
    ) void {
        const integration = self.xdg();
        for (previous_assets.binaries.items) |old_binary_path| {
            const binary_name = std.fs.path.basename(old_binary_path);
            if (assetsContainBinaryName(replacement_assets, binary_name)) continue;
            const link_path = std.fs.path.join(self.allocator, &.{ self.options.binary_directory, binary_name }) catch continue;
            defer self.allocator.free(link_path);
            const points_to_old = linkPointsTo(self.io, link_path, old_binary_path) catch false;
            if (!points_to_old) continue;
            std.Io.Dir.cwd().deleteFile(self.io, link_path) catch |err| {
                self.emitFmt(.warning, "Could not remove obsolete command {s}: {s}", .{ binary_name, @errorName(err) });
                continue;
            };
            if (!containsIgnoreCase(package_name, binary_name)) continue;
            _ = integration.removeDesktopEntry(binary_name) catch |err| {
                self.emitFmt(.warning, "Could not remove obsolete desktop entry for {s}: {s}", .{ binary_name, @errorName(err) });
            };
            _ = integration.removeInstalledIcons(binary_name) catch |err| {
                self.emitFmt(.warning, "Could not remove obsolete icons for {s}: {s}", .{ binary_name, @errorName(err) });
            };
        }
    }

    fn xdg(self: *Manager) xdg_integration.Integration {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .options = .{
                .desktop_directory = self.options.desktop_directory,
                .icon_root = self.options.icon_root,
                .run_cache_updates = self.options.run_cache_updates,
            },
        };
    }

    fn checkCancelled(self: *Manager) !void {
        if (self.dispatcher.operation) |operation|
            if (operation.isCancelled()) return Error.Cancelled;
        if (self.operation_context) |context|
            if (context.isCancelled()) return Error.Cancelled;
        if (self.cancellation) |cancellation|
            if (cancellation.isCancelled()) return Error.Cancelled;
    }

    fn progress(self: *Manager, stage: []const u8, completed: usize, total: ?usize, message: []const u8) void {
        const operation = self.dispatcher.operation orelse return;
        operation.progress(.{
            .stage = stage,
            .completed = @intCast(completed),
            .total = if (total) |value| @intCast(value) else null,
            .percentage = if (total) |value| if (value == 0) 100 else @as(f64, @floatFromInt(completed)) * 100.0 / @as(f64, @floatFromInt(value)) else null,
            .message = message,
        });
    }

    fn reportError(self: *Manager, err: anyerror, message: []const u8) void {
        if (self.dispatcher.operation) |operation|
            operation.reportError(err, message, "local-package", null, false);
    }

    fn emit(self: *Manager, level: events.Level, message: []const u8) void {
        self.dispatcher.raise(.{ .level = level, .text = message });
    }

    fn emitFmt(self: *Manager, level: events.Level, comptime format: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, format, args) catch return;
        defer self.allocator.free(message);
        self.emit(level, message);
    }
};

const OperationScope = struct {
    manager: *Manager,
    operation: ?operations.Operation = null,
    previous: ?*operations.Operation = null,
    attached: bool = false,

    fn init(manager: *Manager, kind: operations.OperationKind, subject: ?[]const u8) OperationScope {
        var scope: OperationScope = .{ .manager = manager, .previous = manager.dispatcher.operation };
        if (scope.previous) |parent| {
            scope.operation = parent.child(.{ .backend = .local_package, .kind = kind, .subject = subject });
        } else if (manager.operation_context) |context| {
            scope.operation = context.begin(.{ .backend = .local_package, .kind = kind, .subject = subject });
        }
        return scope;
    }

    fn attach(self: *OperationScope) void {
        if (self.operation) |*operation| self.manager.dispatcher.setOperation(operation);
        self.attached = true;
    }

    fn finish(self: *OperationScope, status: operations.CompletionStatus) void {
        if (self.operation) |*operation| operation.finish(status);
        if (self.attached) {
            self.manager.dispatcher.setOperation(self.previous);
            self.attached = false;
        }
    }
};

const Assets = struct {
    binaries: std.ArrayList([]u8) = .empty,
    icon_path: ?[]u8 = null,

    fn deinit(self: *Assets, allocator: std.mem.Allocator) void {
        for (self.binaries.items) |path| allocator.free(path);
        self.binaries.deinit(allocator);
        if (self.icon_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

fn assetsContainBinaryName(assets: *const Assets, binary_name: []const u8) bool {
    for (assets.binaries.items) |path| {
        if (std.mem.eql(u8, std.fs.path.basename(path), binary_name)) return true;
    }
    return false;
}

fn packageName(allocator: std.mem.Allocator, archive_path: []const u8) ![]u8 {
    var name = std.fs.path.basename(archive_path);
    const suffixes = [_][]const u8{
        ".pkg.tar.zst", ".pkg.tar.gz", ".tar.zst", ".tar.gz", ".pkg.tar", ".tzst", ".tgz", ".tar",
    };
    for (suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) {
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    try validatePackageName(name);
    return xdg_integration.cleanName(allocator, name);
}

fn validatePackageName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\r\n") != null) return Error.InvalidPackageName;
}

fn validateCommandName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\r\n") != null) return Error.InvalidPackageName;
}

fn safeMode(mode: u32) u32 {
    const permissions = mode & 0o777;
    return if (permissions == 0) 0o644 else permissions;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn pathIsWithin(candidate: []const u8, root_path: []const u8) bool {
    const root = std.mem.trimEnd(u8, root_path, "/");
    return candidate.len > root.len and std.mem.startsWith(u8, candidate, root) and candidate[root.len] == '/';
}

fn directorySize(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !u64 {
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = try directory.statFile(io, entry.path, .{});
        total +|= stat.size;
    }
    return total;
}

fn linkPointsTo(io: std.Io, link_path: []const u8, expected_target: []const u8) !bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const amount = std.Io.Dir.cwd().readLink(io, link_path, &buffer) catch |err| switch (err) {
        error.FileNotFound, error.NotLink => return false,
        else => return err,
    };
    return std.mem.eql(u8, buffer[0..amount], expected_target);
}

fn packageLessThan(_: void, a: Package, b: Package) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn stringLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "local binary packages install list and remove within configured roots" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const archive_path = try std.fs.path.join(testing.allocator, &.{ root, "demo-tool.tar.gz" });
    defer testing.allocator.free(archive_path);
    try archive.writeFixture(testing.allocator, archive_path, .gzip, &.{
        .{ .path = "bin/demo-tool", .contents = "\x7fELFpayload", .permissions = 0o755 },
        .{ .path = "share/demo-tool-64x64.png", .contents = "png" },
    });

    const install_root = try std.fs.path.join(testing.allocator, &.{ root, "installed" });
    defer testing.allocator.free(install_root);
    const bin_root = try std.fs.path.join(testing.allocator, &.{ root, "bin" });
    defer testing.allocator.free(bin_root);
    const desktop_root = try std.fs.path.join(testing.allocator, &.{ root, "applications" });
    defer testing.allocator.free(desktop_root);
    const icon_root = try std.fs.path.join(testing.allocator, &.{ root, "icons" });
    defer testing.allocator.free(icon_root);
    var manager = Manager.init(testing.allocator, testing.io, .{
        .install_directory = install_root,
        .binary_directory = bin_root,
        .desktop_directory = desktop_root,
        .icon_root = icon_root,
        .run_cache_updates = false,
    });
    defer manager.deinit();

    try testing.expect(try manager.installBinariesPackage(archive_path));
    const binary_path = try std.fs.path.join(testing.allocator, &.{ install_root, "demo-tool", "bin", "demo-tool" });
    defer testing.allocator.free(binary_path);
    try std.Io.Dir.cwd().access(testing.io, binary_path, .{});
    const link_path = try std.fs.path.join(testing.allocator, &.{ bin_root, "demo-tool" });
    defer testing.allocator.free(link_path);
    try testing.expect(try linkPointsTo(testing.io, link_path, binary_path));

    const packages = try manager.getInstalledBinaryPackages();
    defer Package.deinitSlice(testing.allocator, packages);
    try testing.expectEqual(@as(usize, 1), packages.len);
    try testing.expectEqualStrings("demo-tool", packages[0].name);
    try testing.expect(packages[0].size > 0);

    try archive.writeFixture(testing.allocator, archive_path, .gzip, &.{
        .{ .path = "replacement", .contents = "\x7fELFreplacement", .permissions = 0o755 },
    });
    try testing.expect(try manager.installBinariesPackage(archive_path));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, binary_path, .{}));
    var obsolete_link_buffer: [1]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readLink(testing.io, link_path, &obsolete_link_buffer));
    const replacement_binary = try std.fs.path.join(testing.allocator, &.{ install_root, "demo-tool", "replacement" });
    defer testing.allocator.free(replacement_binary);
    const replacement_link = try std.fs.path.join(testing.allocator, &.{ bin_root, "replacement" });
    defer testing.allocator.free(replacement_link);
    try testing.expect(try linkPointsTo(testing.io, replacement_link, replacement_binary));

    try testing.expect(try manager.removeBinaryPackages(&.{"demo-tool"}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, replacement_binary, .{}));
    var link_buffer: [1]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readLink(testing.io, replacement_link, &link_buffer));
}

test "archive traversal is rejected before a local package is committed" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const archive_path = try std.fs.path.join(testing.allocator, &.{ root, "unsafe.tar.gz" });
    defer testing.allocator.free(archive_path);
    try archive.writeFixture(testing.allocator, archive_path, .gzip, &.{
        .{ .path = "tool", .contents = "\x7fELFpayload", .permissions = 0o755 },
        .{ .path = "../../escaped", .contents = "no" },
    });
    const install_root = try std.fs.path.join(testing.allocator, &.{ root, "installed" });
    defer testing.allocator.free(install_root);
    var manager = Manager.init(testing.allocator, testing.io, .{
        .install_directory = install_root,
        .run_cache_updates = false,
    });
    defer manager.deinit();
    try testing.expectError(archive.Error.InvalidEntryPath, manager.installBinariesPackage(archive_path));
    const committed = try std.fs.path.join(testing.allocator, &.{ install_root, "unsafe" });
    defer testing.allocator.free(committed);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, committed, .{}));
}

test "installation does not replace an unmanaged command" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const archive_path = try std.fs.path.join(testing.allocator, &.{ root, "conflict.tar.gz" });
    defer testing.allocator.free(archive_path);
    try archive.writeFixture(testing.allocator, archive_path, .gzip, &.{
        .{ .path = "conflict", .contents = "\x7fELFpayload", .permissions = 0o755 },
    });
    const install_root = try std.fs.path.join(testing.allocator, &.{ root, "installed" });
    defer testing.allocator.free(install_root);
    const bin_root = try std.fs.path.join(testing.allocator, &.{ root, "bin" });
    defer testing.allocator.free(bin_root);
    try std.Io.Dir.cwd().createDirPath(testing.io, bin_root);
    const existing_command = try std.fs.path.join(testing.allocator, &.{ bin_root, "conflict" });
    defer testing.allocator.free(existing_command);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = existing_command, .data = "owned elsewhere" });

    var manager = Manager.init(testing.allocator, testing.io, .{
        .install_directory = install_root,
        .binary_directory = bin_root,
        .run_cache_updates = false,
    });
    defer manager.deinit();
    try testing.expectError(Error.CommandConflict, manager.installBinariesPackage(archive_path));
    const contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, existing_command, testing.allocator, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("owned elsewhere", contents);
    const committed = try std.fs.path.join(testing.allocator, &.{ install_root, "conflict" });
    defer testing.allocator.free(committed);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, committed, .{}));
}

test "local packages honor shared cancellation" {
    var context = operations.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    var manager = Manager.init(std.testing.allocator, std.testing.io, .{ .run_cache_updates = false });
    defer manager.deinit();
    manager.setOperationContext(&context);

    context.cancel();
    try std.testing.expectError(Error.Cancelled, manager.installBinariesPackage("cancelled.tar.gz"));
}
