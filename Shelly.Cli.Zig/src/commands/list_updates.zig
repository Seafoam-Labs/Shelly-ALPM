const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const format = @import("../output/format.zig");
const output = @import("../output/config.zig");
const colors = @import("../output/colors.zig");
const table = @import("../output/table.zig");
const parser = @import("../cli/parser.zig");
const shortcodes = @import("../cli/shortcodes.zig");
const runtime = @import("../runtime/context.zig");
const xdg = @import("../runtime/xdg.zig");
const spec = @import("../cli/spec.zig");
const aur_url = @import("../config/aur_url.zig");

const all_command_path = "shelly list-updates all";
const standard_command_path = "shelly list-updates standard";
const appimage_command_path = "shelly list-updates appimage";
const aur_command_path = "shelly list-updates aur";
const flatpak_command_path = "shelly list-updates flatpak";

// Update listings must not trust a cache file's local mtime as an HTTP
// validator. Some repositories publish databases with an older Last-Modified
// value, which can otherwise leave the user-owned planning database stale.
const force_standard_database_refresh = true;

pub const Backend = enum {
    standard,
    appimage,
    aur,
    flatpak,
};

pub const StandardUpdate = struct {
    name: []const u8,
    current_version: []const u8,
    new_version: []const u8,
    download_size: i64,
    size_difference: i64,
    description: []const u8,
    url: []const u8,
    repository: []const u8,
    installed_size: i64,
    depends: []const []const u8,
    optional_depends: []const []const u8,
    licenses: []const []const u8,
    provides: []const []const u8,
    conflicts: []const []const u8,
    groups: []const []const u8,
};

pub const AppImageUpdate = struct {
    name: []const u8,
    version: []const u8,
    download_url: []const u8,
    is_update_available: bool,
};

pub const AurUpdate = struct {
    name: []const u8,
    version: []const u8,
    new_version: []const u8,
    download_size: i64,
    url: []const u8,
    package_base: []const u8,
    description: []const u8,
};

pub const FlatpakUpdate = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    branch: []const u8,
    latest_commit: []const u8,
    summary: []const u8,
    kind: i32,
    remote: []const u8,
    install_level: i32,
    permissions: []const []const u8,
    installed_size: u64,
    ref: []const u8,
    full_ref: []const u8,
    eol: []const u8 = "",
    eol_rebase: []const u8 = "",
};

fn ResultSet(comptime T: type) type {
    return struct {
        items: []const T,
        arena: ?*std.heap.ArenaAllocator = null,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            const arena = self.arena orelse return;
            arena.deinit();
            allocator.destroy(arena);
            self.* = undefined;
        }
    };
}

pub const Result = union(Backend) {
    standard: ResultSet(StandardUpdate),
    appimage: ResultSet(AppImageUpdate),
    aur: ResultSet(AurUpdate),
    flatpak: ResultSet(FlatpakUpdate),

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .standard => |*result| result.deinit(allocator),
            .appimage => |*result| result.deinit(allocator),
            .aur => |*result| result.deinit(allocator),
            .flatpak => |*result| result.deinit(allocator),
        }
    }
};

pub const CheckOptions = struct {
    show_hidden: bool = false,
    no_devel: bool = false,
    aur_url: ?[]const u8 = null,
};

const Real = struct {
    fn collect(
        _: Real,
        context: *runtime.RuntimeContext,
        backend: Backend,
        options: CheckOptions,
    ) !Result {
        return runReal(context, backend, options);
    }
};

/// Collects update metadata without rendering it. Upgrade planning uses this
/// entry point before elevation so every backend reads the invoking user's
/// configuration and cache instead of root's.
pub fn collectUpdates(
    context: *runtime.RuntimeContext,
    backend: Backend,
    options: CheckOptions,
) !Result {
    return runReal(context, backend, options);
}

pub fn resultCount(result: *const Result) usize {
    return switch (result.*) {
        inline else => |items| items.items.len,
    };
}

const SizeDisplay = format.SizeDisplay;
const loadSizeDisplay = format.loadSizeDisplay;
const formatSize = format.formatSignedSize;

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    return dispatchWithRunner(context, invocation, Real{});
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!?u8 {
    if (std.mem.eql(u8, invocation.command.path, all_command_path)) {
        return try executeAllWithRunner(context, invocation, runner);
    }
    const backend = backendForPath(invocation.command.path) orelse return null;
    return try executeWithRunner(context, invocation, backend, runner);
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    runner: anytype,
) anyerror!u8 {
    var result = runner.collect(
        context,
        backend,
        checkOptions(invocation),
    ) catch |err| {
        try writeQueryFailure(context, invocation, backend, err);
        return 1;
    };
    defer result.deinit(context.allocator);

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeJson(context.allocator, &payload.writer, &result);
        try output.writeFrame(context, payload.writer.buffered());
        if (backend == .standard) {
            try writeStandardInfoFrame(context, resultCount(&result));
        }
    } else if (invocation.globals.json) {
        try writeJson(context.allocator, context.stdout, &result);
        try context.stdout.writeByte('\n');
    } else {
        try writePlain(context, &result);
    }
    return 0;
}

fn executeAllWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: anytype,
) anyerror!u8 {
    var results: std.ArrayList(Result) = .empty;
    defer {
        for (results.items) |*result| result.deinit(context.allocator);
        results.deinit(context.allocator);
    }

    var failed = false;
    for (all_backends) |backend| {
        var result = runner.collect(
            context,
            backend,
            checkOptions(invocation),
        ) catch |err| {
            if (backend == .flatpak) {
                if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
                    try writeBackendSkipped(context, invocation, message);
                    continue;
                }
            }
            failed = true;
            try writeQueryFailure(context, invocation, backend, err);
            continue;
        };
        results.append(context.allocator, result) catch |err| {
            result.deinit(context.allocator);
            return err;
        };
    }

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeAllJson(context.allocator, &payload.writer, results.items);
        try output.writeFrame(context, payload.writer.buffered());
        if (standardResultCount(results.items)) |count| {
            try writeStandardInfoFrame(context, count);
        }
    } else if (invocation.globals.json) {
        try writeAllJson(context.allocator, context.stdout, results.items);
        try context.stdout.writeByte('\n');
    } else {
        for (results.items) |*result| try writePlain(context, result);
    }
    return if (failed) 1 else 0;
}

const all_backends = [_]Backend{ .standard, .appimage, .aur, .flatpak };

fn writeQueryFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    err: anyerror,
) !void {
    if (backend == .flatpak) {
        if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
            if (invocation.globals.ui_mode)
                try output.writeErrorFrame(context, message)
            else
                try output.writeFailure(context, message);
            return;
        }
    }
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to query {s} updates: {t}",
        .{ @tagName(backend), err },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
    } else if (invocation.globals.json) {
        try context.stderr.print("{s}\n", .{message});
    } else {
        try output.writeFailure(context, message);
    }
}

fn writeBackendSkipped(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    reason: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Skipping Flatpak updates. {s}",
        .{reason},
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode)
        try output.writeWarningFrame(context, message)
    else
        try output.writeWarning(context, message);
}

fn writeStandardInfoFrame(context: *runtime.RuntimeContext, count: usize) !void {
    const message = if (count == 0)
        "All packages are up to date!"
    else
        try std.fmt.allocPrint(
            context.allocator,
            "{d} standard packages can be updated",
            .{count},
        );
    defer if (count != 0) context.allocator.free(message);
    try output.writeInfoFrame(context, message);
}

fn standardResultCount(results: []const Result) ?usize {
    for (results) |result| {
        if (result == .standard) return result.standard.items.len;
    }
    return null;
}

fn backendForPath(path: []const u8) ?Backend {
    if (std.mem.eql(u8, path, standard_command_path)) return .standard;
    if (std.mem.eql(u8, path, appimage_command_path)) return .appimage;
    if (std.mem.eql(u8, path, aur_command_path)) return .aur;
    if (std.mem.eql(u8, path, flatpak_command_path)) return .flatpak;
    return null;
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return true;
    }
    return false;
}

fn writeJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: *const Result,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    try writeJsonItems(allocator, &json, result);
    try json.endArray();
}

fn writeAllJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    results: []const Result,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };

    try json.beginObject();

    try json.objectField("Packages");
    try json.beginArray();
    for (results) |*result| {
        if (result.* == .standard) {
            const sorted = try sortedStandard(allocator, result.standard.items);
            defer allocator.free(sorted);
            for (sorted) |update| try writeStandardJson(&json, update);
        }
    }
    try json.endArray();

    try json.objectField("Aur");
    try json.beginArray();
    for (results) |*result| {
        if (result.* == .aur) {
            const sorted = try sortedAur(allocator, result.aur.items);
            defer allocator.free(sorted);
            for (sorted) |update| try writeAurJson(&json, update);
        }
    }
    try json.endArray();

    try json.objectField("AppImage");
    try json.beginArray();
    for (results) |*result| {
        if (result.* == .appimage) {
            for (result.appimage.items) |update| try writeAppImageJson(&json, update);
        }
    }
    try json.endArray();

    try json.objectField("Flatpak");
    try json.beginArray();
    for (results) |*result| {
        if (result.* == .flatpak) {
            const sorted = try sortedFlatpak(allocator, result.flatpak.items);
            defer allocator.free(sorted);
            for (sorted) |update| try writeFlatpakJson(&json, update);
        }
    }
    try json.endArray();

    try json.endObject();
}

fn writeJsonItems(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    result: *const Result,
) !void {
    switch (result.*) {
        .standard => |items| {
            const sorted = try sortedStandard(allocator, items.items);
            defer allocator.free(sorted);
            for (sorted) |update| try writeStandardJson(json, update);
        },
        .aur => |items| {
            const sorted = try sortedAur(allocator, items.items);
            defer allocator.free(sorted);
            for (sorted) |update| try writeAurJson(json, update);
        },
        .appimage => |items| for (items.items) |update| try writeAppImageJson(json, update),
        .flatpak => |items| {
            const sorted = try sortedFlatpak(allocator, items.items);
            defer allocator.free(sorted);
            for (sorted) |update| try writeFlatpakJson(json, update);
        },
    }
}

fn writeStandardJson(json: *std.json.Stringify, update: StandardUpdate) !void {
    try json.beginObject();
    try field(json, "Name", update.name);
    try field(json, "CurrentVersion", update.current_version);
    try field(json, "NewVersion", update.new_version);
    try field(json, "DownloadSize", update.download_size);
    try field(json, "SizeDifference", update.size_difference);
    try field(json, "Description", update.description);
    try field(json, "Url", update.url);
    try field(json, "Repository", update.repository);
    try field(json, "InstalledSize", update.installed_size);
    try field(json, "Depends", update.depends);
    try field(json, "OptDepends", update.optional_depends);
    try field(json, "Licenses", update.licenses);
    try field(json, "Provides", update.provides);
    try field(json, "Conflicts", update.conflicts);
    try field(json, "Groups", update.groups);
    try json.endObject();
}

fn writeAurJson(json: *std.json.Stringify, update: AurUpdate) !void {
    try json.beginObject();
    try field(json, "Name", update.name);
    try field(json, "Version", update.version);
    try field(json, "NewVersion", update.new_version);
    try field(json, "DownloadSize", update.download_size);
    try field(json, "Url", update.url);
    try field(json, "PackageBase", update.package_base);
    try field(json, "Description", update.description);
    try json.endObject();
}

fn writeAppImageJson(json: *std.json.Stringify, update: AppImageUpdate) !void {
    try json.beginObject();
    try field(json, "Name", update.name);
    try field(json, "Version", update.version);
    try field(json, "DownloadUrl", update.download_url);
    try field(json, "IsUpdateAvailable", update.is_update_available);
    try json.endObject();
}

fn writeFlatpakJson(json: *std.json.Stringify, update: FlatpakUpdate) !void {
    try json.beginObject();
    try field(json, "Id", update.id);
    try field(json, "Name", update.name);
    try field(json, "Version", update.version);
    try field(json, "Arch", update.arch);
    try field(json, "Branch", update.branch);
    try field(json, "LatestCommit", update.latest_commit);
    try field(json, "Summary", update.summary);
    try field(json, "Kind", update.kind);
    try field(json, "IconPath", null);
    try field(json, "Description", "");
    try field(json, "Releases", &[_]u8{});
    try field(json, "Categories", &[_]u8{});
    try field(json, "Remote", update.remote);
    try field(json, "InstallLevel", update.install_level);
    try field(json, "Permissions", update.permissions);
    try field(json, "InstalledSize", update.installed_size);
    try field(json, "Ref", update.ref);
    try field(json, "FullRef", update.full_ref);
    try field(json, "Eol", update.eol);
    try field(json, "EolRebase", update.eol_rebase);
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn writePlain(context: *runtime.RuntimeContext, result: *const Result) !void {
    switch (result.*) {
        .standard => |items| try writeStandardPlain(context, items.items),
        .aur => |items| try writeAurPlain(context, items.items),
        .appimage => |items| try writeAppImagePlain(context, items.items),
        .flatpak => |items| try writeFlatpakPlain(context, items.items),
    }
}

fn writeStandardPlain(context: *runtime.RuntimeContext, updates: []const StandardUpdate) !void {
    if (updates.len == 0) return writeColoredLine(context, .success, "All packages are up to date!");

    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const sorted = try sortedStandard(allocator, updates);
    const rows = try allocator.alloc([]const []const u8, sorted.len);
    const size_display = try loadSizeDisplay(context);
    for (sorted, rows) |update, *row| {
        const cells = try allocator.alloc([]const u8, 5);
        cells[0] = update.name;
        cells[1] = update.current_version;
        cells[2] = update.new_version;
        cells[3] = try formatSize(allocator, size_display, update.download_size);
        cells[4] = try formatSize(allocator, size_display, update.size_difference);
        row.* = cells;
    }
    try table.write(
        context,
        &.{ "Name", "Current Version", "New Version", "Download Size", "Size Difference" },
        rows,
    );
    try context.stdout.writeByte('\n');
    const message = try std.fmt.allocPrint(allocator, "{d} standard packages can be updated", .{updates.len});
    try writeColoredLine(context, .warning, message);
}

fn writeAurPlain(context: *runtime.RuntimeContext, updates: []const AurUpdate) !void {
    if (updates.len == 0) return writeColoredLine(context, .warning, "All AUR packages are up to date.");

    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const sorted = try sortedAur(allocator, updates);
    const rows = try allocator.alloc([]const []const u8, sorted.len);
    for (sorted, rows) |update, *row| {
        const description = if (std.mem.trim(u8, update.description, " \t\r\n").len == 0)
            "No Description Available"
        else
            truncate(update.description, 50);
        const cells = try allocator.alloc([]const u8, 4);
        cells[0] = update.name;
        cells[1] = update.version;
        cells[2] = update.new_version;
        cells[3] = description;
        row.* = cells;
    }
    try table.write(
        context,
        &.{ "Name", "Installed", "Available", "Description" },
        rows,
    );
    const message = try std.fmt.allocPrint(allocator, "AUR Total: {d} packages need updates", .{updates.len});
    try writeColoredLine(context, .warning, message);
}

fn writeAppImagePlain(context: *runtime.RuntimeContext, updates: []const AppImageUpdate) !void {
    if (updates.len == 0) return writeColoredLine(context, .warning, "No appimage updates available");
    for (updates) |update| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "{s} {s} is available",
            .{ update.name, update.version },
        );
        defer context.allocator.free(message);
        try writeColoredLine(context, .warning, message);
    }
}

fn writeFlatpakPlain(context: *runtime.RuntimeContext, updates: []const FlatpakUpdate) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const sorted = try sortedFlatpak(allocator, updates);
    const rows = try allocator.alloc([]const []const u8, sorted.len);
    for (sorted, rows) |update, *row| {
        const cells = try allocator.alloc([]const u8, 4);
        cells[0] = update.name;
        cells[1] = update.id;
        cells[2] = update.version;
        cells[3] = if (update.permissions.len == 0)
            "No changes"
        else
            try std.mem.join(allocator, "\n", update.permissions);
        row.* = cells;
    }
    try table.write(
        context,
        &.{ "Name", "Id", "Version", "Permissions" },
        rows,
    );
    try context.stdout.writeByte('\n');
    const message = try std.fmt.allocPrint(allocator, "Flatpak Total: {d} packages", .{updates.len});
    try writeColoredLine(context, .warning, message);
}

fn writeColoredLine(
    context: *runtime.RuntimeContext,
    color: colors.Color,
    message: []const u8,
) !void {
    try colors.printLine(context, color, "{s}", .{message});
}

fn sortedStandard(allocator: std.mem.Allocator, updates: []const StandardUpdate) ![]StandardUpdate {
    const sorted = try allocator.dupe(StandardUpdate, updates);
    std.mem.sort(StandardUpdate, sorted, {}, struct {
        fn lessThan(_: void, left: StandardUpdate, right: StandardUpdate) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return sorted;
}

fn sortedAur(allocator: std.mem.Allocator, updates: []const AurUpdate) ![]AurUpdate {
    const sorted = try allocator.dupe(AurUpdate, updates);
    std.mem.sort(AurUpdate, sorted, {}, struct {
        fn lessThan(_: void, left: AurUpdate, right: AurUpdate) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return sorted;
}

fn sortedFlatpak(allocator: std.mem.Allocator, updates: []const FlatpakUpdate) ![]FlatpakUpdate {
    const sorted = try allocator.dupe(FlatpakUpdate, updates);
    std.mem.sort(FlatpakUpdate, sorted, {}, struct {
        fn lessThan(_: void, left: FlatpakUpdate, right: FlatpakUpdate) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
    return sorted;
}

fn truncate(value: []const u8, maximum: usize) []const u8 {
    return format.truncate(value, maximum);
}

pub fn checkOptions(invocation: *const parser.Invocation) CheckOptions {
    return .{
        .show_hidden = optionEnabled(invocation, "--show-hidden"),
        .no_devel = optionEnabled(invocation, "--no-devel"),
        .aur_url = aur_url.overrideValue(invocation),
    };
}

fn runReal(
    context: *runtime.RuntimeContext,
    backend: Backend,
    options: CheckOptions,
) !Result {
    return switch (backend) {
        .standard => runStandard(context),
        .aur => runAur(context, options),
        .appimage => runAppImage(context),
        .flatpak => runFlatpak(context),
    };
}

fn runStandard(context: *runtime.RuntimeContext) !Result {
    const database_path = try xdg.shellyCache(context, &.{"db"});
    defer context.allocator.free(database_path);
    try std.Io.Dir.cwd().createDirPath(context.io, database_path);

    var manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        .{
            .use_root = false,
            .temp_root_path = database_path,
        },
    );
    defer manager.deinit();
    try manager.sync_for_update_check(force_standard_database_refresh);
    const native_updates = try manager.get_updates_available();
    defer Zigalpm.alpm.bindings.libalpm.OwnedPackageWithUpdate.deinitSlice(
        context.allocator,
        native_updates,
    );

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer {
        arena.deinit();
        context.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const updates = try allocator.alloc(StandardUpdate, native_updates.len);
    for (native_updates, updates) |native, *update| {
        const old_package = native.old_package;
        const new_package = native.new_package;
        update.* = .{
            .name = try allocator.dupe(u8, new_package.name_value),
            .current_version = try allocator.dupe(u8, old_package.version_value),
            .new_version = try allocator.dupe(u8, new_package.version_value),
            .download_size = new_package.download_size_value,
            .size_difference = new_package.install_size_value - old_package.install_size_value,
            .description = try allocator.dupe(u8, new_package.description_value orelse ""),
            .url = try allocator.dupe(u8, new_package.url_value orelse ""),
            .repository = try allocator.dupe(u8, new_package.repository_value orelse ""),
            .installed_size = new_package.install_size_value,
            .depends = try dupeStrings(allocator, new_package.depends_value),
            .optional_depends = try dupeStrings(allocator, new_package.optional_depends_value),
            .licenses = try dupeStrings(allocator, new_package.licenses_value),
            .provides = try dupeStrings(allocator, new_package.provides_value),
            .conflicts = try dupeStrings(allocator, new_package.conflicts_value),
            .groups = try dupeStrings(allocator, new_package.groups_value),
        };
    }
    return .{ .standard = .{ .items = updates, .arena = arena } };
}

fn runAur(context: *runtime.RuntimeContext, options: CheckOptions) !Result {
    const database_path = try xdg.shellyCache(context, &.{"db"});
    defer context.allocator.free(database_path);
    try std.Io.Dir.cwd().createDirPath(context.io, database_path);

    const aur_base = try aur_url.resolve(context, options.aur_url);
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .aur_git_base_url = aur_base,
        .use_temp_path = true,
        .temp_path = database_path,
        .show_hidden_packages = options.show_hidden,
    });
    defer manager.deinit();
    const native_updates = try manager.getPackagesNeedingUpdate(!options.no_devel);
    defer Zigalpm.aur.models.Update.deinitSlice(context.allocator, native_updates);

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer {
        arena.deinit();
        context.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const updates = try allocator.alloc(AurUpdate, native_updates.len);
    for (native_updates, updates) |native, *update| {
        update.* = .{
            .name = try allocator.dupe(u8, native.name),
            .version = try allocator.dupe(u8, native.version),
            .new_version = try allocator.dupe(u8, native.new_version),
            .download_size = native.download_size,
            .url = try allocator.dupe(u8, native.url),
            .package_base = try allocator.dupe(u8, native.package_base),
            .description = try allocator.dupe(u8, native.description),
        };
    }
    return .{ .aur = .{ .items = updates, .arena = arena } };
}

fn runAppImage(context: *runtime.RuntimeContext) !Result {
    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const config_home = try xdg.configHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ config_home, "shelly", "appimage-metadata-v2.db" },
    );
    defer context.allocator.free(local_db_path);

    var manager = Zigalpm.appimage.UpdateManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    var native_updates = try manager.get_updates();
    defer native_updates.deinit();

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer {
        arena.deinit();
        context.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const updates = try allocator.alloc(AppImageUpdate, native_updates.items.len);
    for (native_updates.items, updates) |native, *update| {
        update.* = .{
            .name = try allocator.dupe(u8, native.name),
            .version = try allocator.dupe(u8, native.version),
            .download_url = try allocator.dupe(u8, native.download_url),
            .is_update_available = native.is_update_available,
        };
    }
    return .{ .appimage = .{ .items = updates, .arena = arena } };
}

fn runFlatpak(context: *runtime.RuntimeContext) !Result {
    var manager = Zigalpm.FlatpakManager{
        .allocator = context.allocator,
        .io = context.io,
    };
    defer manager.deinit();
    const native_updates = try manager.get_updates_flatpak();
    defer Zigalpm.flatpak.InstalledRef.deinitSlice(
        context.allocator,
        native_updates,
    );

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer {
        arena.deinit();
        context.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const updates = try allocator.alloc(FlatpakUpdate, native_updates.len);
    for (native_updates, updates) |native, *update| {
        const ref = try allocator.dupe(u8, native.reference);
        update.* = .{
            .id = try allocator.dupe(u8, native.id),
            .name = try allocator.dupe(u8, native.name),
            .version = try allocator.dupe(u8, native.version),
            .arch = try allocator.dupe(u8, native.arch),
            .branch = try allocator.dupe(u8, native.branch),
            .latest_commit = try allocator.dupe(u8, native.latest_commit),
            .summary = try allocator.dupe(u8, native.summary),
            .kind = @intFromEnum(native.kind),
            .remote = try allocator.dupe(u8, native.origin),
            .install_level = @intFromEnum(native.scope),
            .permissions = try dupeStrings(allocator, native.permissions),
            .installed_size = native.installed_size,
            .ref = ref,
            .full_ref = try std.fmt.allocPrint(
                allocator,
                "{s}:{s}",
                .{ native.origin, ref },
            ),
            .eol = if (native.eol) |value| try allocator.dupe(u8, value) else "",
            .eol_rebase = if (native.eol_rebase) |value| try allocator.dupe(u8, value) else "",
        };
    }
    return .{ .flatpak = .{ .items = updates, .arena = arena } };
}

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn dupeStrings(
    allocator: std.mem.Allocator,
    values: anytype,
) ![]const []const u8 {
    const copies = try allocator.alloc([]const u8, values.len);
    for (values, copies) |value, *copy| copy.* = try allocator.dupe(u8, value);
    return copies;
}

fn parseTestArguments(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    arguments: []const []const u8,
) !parser.Outcome {
    const translation = try shortcodes.translate(allocator, manifest, arguments);
    const translated = translation.arguments() orelse return error.ShortcodeTranslationFailed;
    return parser.parse(allocator, manifest, translated);
}

fn decodeFirstTestFrame(allocator: std.mem.Allocator, rendered: []const u8) ![]u8 {
    const prefix = "[JSON]";
    const suffix = "[/JSON]";
    const prefix_start = std.mem.indexOf(u8, rendered, prefix) orelse return error.MissingFrame;
    const payload_start = prefix_start + prefix.len;
    const suffix_start = std.mem.indexOfPos(u8, rendered, payload_start, suffix) orelse
        return error.MissingFrame;
    const encoded = rendered[payload_start..suffix_start];
    const decoded_length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_length);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn emptyTestResult(backend: Backend) Result {
    return switch (backend) {
        .standard => .{ .standard = .{ .items = &.{} } },
        .appimage => .{ .appimage = .{ .items = &.{} } },
        .aur => .{ .aur = .{ .items = &.{} } },
        .flatpak => .{ .flatpak = .{ .items = &.{} } },
    };
}

test "standard list-updates forces an unconditional database refresh" {
    try std.testing.expect(force_standard_database_refresh);
}

test "list-updates routes long and short forms to each backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const Case = struct {
        arguments: []const []const u8,
        backend: Backend,
    };
    const cases = [_]Case{
        .{ .arguments = &.{ "list-updates", "standard" }, .backend = .standard },
        .{ .arguments = &.{"-Ps"}, .backend = .standard },
        .{ .arguments = &.{ "list-updates", "appimage" }, .backend = .appimage },
        .{ .arguments = &.{"-Pi"}, .backend = .appimage },
        .{ .arguments = &.{ "list-updates", "aur" }, .backend = .aur },
        .{ .arguments = &.{"-Pa"}, .backend = .aur },
        .{ .arguments = &.{ "list-updates", "flatpak" }, .backend = .flatpak },
        .{ .arguments = &.{"-Pf"}, .backend = .flatpak },
    };

    for (cases) |case| {
        const outcome = try parseTestArguments(arena.allocator(), &manifest, case.arguments);
        try std.testing.expect(outcome == .dispatch);
        var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stdout.deinit();
        var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer stderr.deinit();
        var context: runtime.RuntimeContext = .{
            .allocator = arena.allocator(),
            .io = std.testing.io,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
        };
        const Capture = struct {
            backend: ?Backend = null,

            fn collect(
                self: *@This(),
                _: *runtime.RuntimeContext,
                backend: Backend,
                _: CheckOptions,
            ) !Result {
                self.backend = backend;
                return switch (backend) {
                    .standard => .{ .standard = .{ .items = &.{} } },
                    .appimage => .{ .appimage = .{ .items = &.{} } },
                    .aur => .{ .aur = .{ .items = &.{} } },
                    .flatpak => .{ .flatpak = .{ .items = &.{} } },
                };
            }
        };
        var capture: Capture = .{};

        try std.testing.expectEqual(
            @as(?u8, 0),
            try dispatchWithRunner(&context, &outcome.dispatch, &capture),
        );
        try std.testing.expectEqual(case.backend, capture.backend.?);
    }
}

test "bare list-updates shortcode queries every backend in order and emits grouped JSON" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "-P", "--json", "--show-hidden" },
    );
    try std.testing.expect(outcome == .dispatch);
    const Capture = struct {
        backends: [4]Backend = undefined,
        show_hidden: [4]bool = undefined,
        count: usize = 0,

        fn collect(
            self: *@This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            options: CheckOptions,
        ) !Result {
            self.backends[self.count] = backend;
            self.show_hidden[self.count] = options.show_hidden;
            self.count += 1;
            if (backend == .appimage) {
                return .{ .appimage = .{ .items = &.{.{
                    .name = "Widget",
                    .version = "2.0",
                    .download_url = "https://example.test/widget",
                    .is_update_available = true,
                }} } };
            }
            return emptyTestResult(backend);
        }
    };
    var capture: Capture = .{};

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture),
    );
    try std.testing.expectEqual(@as(usize, 4), capture.count);
    try std.testing.expectEqualSlices(
        Backend,
        &.{ .standard, .appimage, .aur, .flatpak },
        capture.backends[0..capture.count],
    );
    for (capture.show_hidden[0..capture.count]) |show_hidden| {
        try std.testing.expect(show_hidden);
    }
    try std.testing.expectEqualStrings(
        "{\"Packages\":[],\"Aur\":[],\"AppImage\":[{\"Name\":\"Widget\",\"Version\":\"2.0\",\"DownloadUrl\":\"https://example.test/widget\",\"IsUpdateAvailable\":true}],\"Flatpak\":[]}\n",
        tc.stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", tc.stderr.writer.buffered());
}

test "bare list-updates shortcode renders empty plain and UI output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const Empty = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            _: CheckOptions,
        ) !Result {
            return emptyTestResult(backend);
        }
    };

    const plain_outcome = try parseTestArguments(arena.allocator(), &manifest, &.{"-P"});
    try std.testing.expect(plain_outcome == .dispatch);
    var plain_stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plain_stdout.deinit();
    var plain_stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plain_stderr.deinit();
    var plain_context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &plain_stdout.writer,
        .stderr = &plain_stderr.writer,
    };
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&plain_context, &plain_outcome.dispatch, Empty{}),
    );
    const rendered_plain = plain_stdout.writer.buffered();
    const standard_index = std.mem.indexOf(u8, rendered_plain, "All packages are up to date!").?;
    const appimage_index = std.mem.indexOf(u8, rendered_plain, "No appimage updates available").?;
    const aur_index = std.mem.indexOf(u8, rendered_plain, "All AUR packages are up to date.").?;
    const flatpak_index = std.mem.indexOf(u8, rendered_plain, "Flatpak Total: 0 packages").?;
    try std.testing.expect(standard_index < appimage_index);
    try std.testing.expect(appimage_index < aur_index);
    try std.testing.expect(aur_index < flatpak_index);

    const ui_outcome = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "-P", "--ui-mode" },
    );
    try std.testing.expect(ui_outcome == .dispatch);
    var ui_stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer ui_stdout.deinit();
    var ui_stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer ui_stderr.deinit();
    var ui_context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &ui_stdout.writer,
        .stderr = &ui_stderr.writer,
    };
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&ui_context, &ui_outcome.dispatch, Empty{}),
    );
    const decoded = try decodeFirstTestFrame(std.testing.allocator, ui_stdout.writer.buffered());
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(
        "{\"Packages\":[],\"Aur\":[],\"AppImage\":[],\"Flatpak\":[]}",
        decoded,
    );
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ui_stdout.writer.buffered(), "[JSON]"));
}

test "bare list-updates shortcode continues after a backend failure" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "-P", "--json" },
    );
    try std.testing.expect(outcome == .dispatch);
    const Capture = struct {
        calls: usize = 0,

        fn collect(
            self: *@This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            _: CheckOptions,
        ) !Result {
            self.calls += 1;
            if (backend == .appimage) return error.QueryFailed;
            return emptyTestResult(backend);
        }
    };
    var capture: Capture = .{};

    try std.testing.expectEqual(
        @as(?u8, 1),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, &capture),
    );
    try std.testing.expectEqual(@as(usize, 4), capture.calls);
    try std.testing.expectEqualStrings(
        "{\"Packages\":[],\"Aur\":[],\"AppImage\":[],\"Flatpak\":[]}\n",
        tc.stdout.writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, tc.stderr.writer.buffered(), "Unable to query appimage updates") != null);
}

test "aggregate list-updates skips an unavailable Flatpak backend without failing" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "-P", "--json" },
    );
    try std.testing.expect(outcome == .dispatch);
    const Unavailable = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            _: CheckOptions,
        ) !Result {
            if (backend == .flatpak)
                return error.FlatpakBackendUnavailable;
            return emptyTestResult(backend);
        }
    };

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, Unavailable{}),
    );
    try std.testing.expectEqualStrings(
        "{\"Packages\":[],\"Aur\":[],\"AppImage\":[],\"Flatpak\":[]}\n",
        tc.stdout.writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stderr.writer.buffered(),
        "Skipping Flatpak updates",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        tc.stderr.writer.buffered(),
        "Install flatpak and shelly-flatpak-backend",
    ) != null);
}

test "list-updates forwards AUR show-hidden and ignores unsupported paths" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const aur_outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "list-updates", "aur", "--show-hidden", "--no-devel" },
    );
    try std.testing.expect(aur_outcome == .dispatch);
    const Capture = struct {
        show_hidden: bool = false,
        no_devel: bool = false,

        fn collect(
            self: *@This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            options: CheckOptions,
        ) !Result {
            try std.testing.expectEqual(Backend.aur, backend);
            self.show_hidden = options.show_hidden;
            self.no_devel = options.no_devel;
            return .{ .aur = .{ .items = &.{} } };
        }
    };
    var capture: Capture = .{};

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &aur_outcome.dispatch, &capture),
    );
    try std.testing.expect(capture.show_hidden);
    try std.testing.expect(capture.no_devel);

    const unsupported_outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "search", "standard", "linux" },
    );
    try std.testing.expect(unsupported_outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, null),
        try dispatchWithRunner(&tc.context, &unsupported_outcome.dispatch, &capture),
    );
}

test "standard list-updates sorts and emits compatibility JSON" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "list-updates", "standard", "--json" },
    );
    try std.testing.expect(outcome == .dispatch);
    const StandardFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .standard = .{ .items = &.{
                .{
                    .name = "zlib",
                    .current_version = "1.2",
                    .new_version = "1.3",
                    .download_size = 2048,
                    .size_difference = 128,
                    .description = "Compression library",
                    .url = "https://zlib.net",
                    .repository = "core",
                    .installed_size = 4096,
                    .depends = &.{"glibc"},
                    .optional_depends = &.{},
                    .licenses = &.{"Zlib"},
                    .provides = &.{},
                    .conflicts = &.{},
                    .groups = &.{},
                },
                .{
                    .name = "alpha",
                    .current_version = "1.0",
                    .new_version = "2.0",
                    .download_size = 1024,
                    .size_difference = -64,
                    .description = "First package",
                    .url = "https://example.test/alpha",
                    .repository = "extra",
                    .installed_size = 8192,
                    .depends = &.{},
                    .optional_depends = &.{"docs: documentation"},
                    .licenses = &.{"MIT"},
                    .provides = &.{"alpha-api"},
                    .conflicts = &.{"alpha-old"},
                    .groups = &.{"demo"},
                },
            } } };
        }
    };

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, StandardFixture{}),
    );
    const rendered = tc.stdout.writer.buffered();
    const alpha_index = std.mem.indexOf(u8, rendered, "\"Name\":\"alpha\"") orelse return error.MissingAlpha;
    const zlib_index = std.mem.indexOf(u8, rendered, "\"Name\":\"zlib\"") orelse return error.MissingZlib;
    try std.testing.expect(alpha_index < zlib_index);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"CurrentVersion\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"SizeDifference\":-64") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"OptDepends\":[\"docs: documentation\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "current_version") == null);
    try std.testing.expectEqual(@as(usize, 0), tc.stderr.writer.buffered().len);
}

test "standard and AUR plain output mirrors legacy tables and empty states" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const AurFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .aur = .{ .items = &.{
                .{
                    .name = "zeta",
                    .version = "1",
                    .new_version = "2",
                    .download_size = 0,
                    .url = "https://aur.archlinux.org/packages/zeta",
                    .package_base = "zeta",
                    .description = "This description is deliberately longer than fifty characters total.",
                },
                .{
                    .name = "alpha",
                    .version = "3",
                    .new_version = "4",
                    .download_size = 0,
                    .url = "https://aur.archlinux.org/packages/alpha",
                    .package_base = "alpha",
                    .description = "",
                },
            } } };
        }
    };
    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "list-updates", "aur" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, AurFixture{}),
    );
    const aur_rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "Installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "Available") != null);
    const alpha_index = std.mem.indexOf(u8, aur_rendered, "alpha") orelse return error.MissingAlpha;
    const zeta_index = std.mem.indexOf(u8, aur_rendered, "zeta") orelse return error.MissingZeta;
    try std.testing.expect(alpha_index < zeta_index);
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "No Description Available") != null);
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "This description is deliberately longer than fifty") != null);
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "characters total") == null);
    try std.testing.expect(std.mem.indexOf(u8, aur_rendered, "Total: 2 packages need updates") != null);

    tc.stdout.writer.end = 0;
    const EmptyStandardFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .standard = .{ .items = &.{} } };
        }
    };
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "list-updates", "standard" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, EmptyStandardFixture{}),
    );
    try std.testing.expectEqualStrings("All packages are up to date!\n", tc.stdout.writer.buffered());
}

test "standard UI output contains update and informational frames" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "list-updates", "standard", "--ui-mode" },
    );
    try std.testing.expect(outcome == .dispatch);
    const EmptyStandardFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .standard = .{ .items = &.{} } };
        }
    };

    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, EmptyStandardFixture{}),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"),
    );
    const decoded = try decodeFirstTestFrame(tc.arena.allocator(), tc.stdout.writer.buffered());
    try std.testing.expectEqualStrings("[]", decoded);
}

test "list-updates reports runner failures by output mode" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Failure = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return error.TestUpdateFailure;
        }
    };

    var outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "list-updates", "aur", "--json" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 1),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, Failure{}),
    );
    try std.testing.expectEqualStrings("", tc.stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, tc.stderr.writer.buffered(), "TestUpdateFailure") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "list-updates", "aur", "--ui-mode" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 1),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, Failure{}),
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));
}

test "AppImage list-updates preserves order and renders legacy output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const PopulatedFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .appimage = .{ .items = &.{
                .{
                    .name = "Zeta",
                    .version = "2.0",
                    .download_url = "https://example.test/zeta.AppImage",
                    .is_update_available = true,
                },
                .{
                    .name = "Alpha",
                    .version = "1.5",
                    .download_url = "https://example.test/alpha.AppImage",
                    .is_update_available = true,
                },
            } } };
        }
    };

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "list-updates", "appimage", "--json" },
    );
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, PopulatedFixture{}),
    );
    const json = tc.stdout.writer.buffered();
    const zeta_index = std.mem.indexOf(u8, json, "\"Name\":\"Zeta\"") orelse return error.MissingZeta;
    const alpha_index = std.mem.indexOf(u8, json, "\"Name\":\"Alpha\"") orelse return error.MissingAlpha;
    try std.testing.expect(zeta_index < alpha_index);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"DownloadUrl\":\"https://example.test/zeta.AppImage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"IsUpdateAvailable\":true") != null);

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "list-updates", "appimage" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, PopulatedFixture{}),
    );
    try std.testing.expectEqualStrings(
        "Zeta 2.0 is available\nAlpha 1.5 is available\n",
        tc.stdout.writer.buffered(),
    );

    tc.stdout.writer.end = 0;
    const EmptyAppImageFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .appimage = .{ .items = &.{} } };
        }
    };
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, EmptyAppImageFixture{}),
    );
    try std.testing.expectEqualStrings("No appimage updates available\n", tc.stdout.writer.buffered());
}

test "Flatpak list-updates sorts compatibility JSON and renders table" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const FlatpakFixture = struct {
        fn collect(
            _: @This(),
            _: *runtime.RuntimeContext,
            _: Backend,
            _: CheckOptions,
        ) !Result {
            return .{ .flatpak = .{ .items = &.{
                .{
                    .id = "org.zeta.App",
                    .name = "Zeta",
                    .version = "2.0",
                    .arch = "x86_64",
                    .branch = "stable",
                    .latest_commit = "zeta-commit",
                    .summary = "Zeta app",
                    .kind = 0,
                    .remote = "flathub",
                    .install_level = 1,
                    .permissions = &.{ "Add: network", "Remove: ipc" },
                    .installed_size = 2048,
                    .ref = "app/org.zeta.App/x86_64/stable",
                    .full_ref = "flathub:app/org.zeta.App/x86_64/stable",
                },
                .{
                    .id = "org.alpha.App",
                    .name = "Alpha",
                    .version = "1.0",
                    .arch = "x86_64",
                    .branch = "stable",
                    .latest_commit = "alpha-commit",
                    .summary = "Alpha app",
                    .kind = 0,
                    .remote = "flathub",
                    .install_level = 1,
                    .permissions = &.{},
                    .installed_size = 1024,
                    .ref = "app/org.alpha.App/x86_64/stable",
                    .full_ref = "flathub:app/org.alpha.App/x86_64/stable",
                },
            } } };
        }
    };

    var outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "list-updates", "flatpak", "--ui-mode" },
    );
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, FlatpakFixture{}),
    );
    const framed = tc.stdout.writer.buffered();
    const decoded = try decodeFirstTestFrame(tc.arena.allocator(), framed);
    const alpha_index = std.mem.indexOf(u8, decoded, "\"Id\":\"org.alpha.App\"") orelse return error.MissingAlpha;
    const zeta_index = std.mem.indexOf(u8, decoded, "\"Id\":\"org.zeta.App\"") orelse return error.MissingZeta;
    try std.testing.expect(alpha_index < zeta_index);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"Permissions\":[\"Add: network\",\"Remove: ipc\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"FullRef\":\"flathub:app/org.zeta.App/x86_64/stable\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, framed, "[JSON]"));

    tc.stdout.writer.end = 0;
    outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "list-updates", "flatpak" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expectEqual(
        @as(?u8, 0),
        try dispatchWithRunner(&tc.context, &outcome.dispatch, FlatpakFixture{}),
    );
    const plain = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Id") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Version") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Permissions") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "No changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Add: network") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Remove: ipc") != null);
    const plain_alpha_index = std.mem.indexOf(u8, plain, "org.alpha.App") orelse return error.MissingAlpha;
    const plain_zeta_index = std.mem.indexOf(u8, plain, "org.zeta.App") orelse return error.MissingZeta;
    try std.testing.expect(plain_alpha_index < plain_zeta_index);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Total: 2 packages") != null);
}

test "Flatpak list-updates renders EOL annotations in JSON output" {
    var output_buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_buffer.deinit();

    const updates = [_]FlatpakUpdate{
        .{
            .id = "dev.bragefuglseth.Keypunch",
            .name = "Keypunch",
            .version = "1.0",
            .arch = "x86_64",
            .branch = "stable",
            .latest_commit = "abc",
            .summary = "Typing tutor",
            .kind = 0,
            .remote = "flathub",
            .install_level = 1,
            .permissions = &.{},
            .installed_size = 1024,
            .ref = "app/dev.bragefuglseth.Keypunch/x86_64/stable",
            .full_ref = "flathub:app/dev.bragefuglseth.Keypunch/x86_64/stable",
            .eol = "Deprecated.",
            .eol_rebase = "no.bragefuglseth.Keypunch",
        },
        .{
            .id = "org.example.Dead",
            .name = "Dead",
            .version = "2.0",
            .arch = "x86_64",
            .branch = "stable",
            .latest_commit = "def",
            .summary = "Dead app",
            .kind = 0,
            .remote = "flathub",
            .install_level = 1,
            .permissions = &.{},
            .installed_size = 512,
            .ref = "app/org.example.Dead/x86_64/stable",
            .full_ref = "flathub:app/org.example.Dead/x86_64/stable",
            .eol = "No longer maintained",
        },
    };
    const result: Result = .{ .flatpak = .{ .items = &updates } };
    try writeJson(std.testing.allocator, &output_buffer.writer, &result);
    const rendered = output_buffer.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Eol\":\"Deprecated.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"EolRebase\":\"no.bragefuglseth.Keypunch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Eol\":\"No longer maintained\"") != null);
}
