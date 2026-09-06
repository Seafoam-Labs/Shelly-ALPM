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
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");
const aur_url = @import("../config/aur_url.zig");

const standard_command_path = "shelly list standard";
const appimage_command_path = "shelly list appimage";
const aur_command_path = "shelly list aur";
const flatpak_command_path = "shelly list flatpak";

pub const Backend = enum { standard, appimage, aur, flatpak };

const ListOptions = struct {
    show_hidden: bool = false,
    required_by: bool = false,
    optional_for: bool = false,
    aur_url: ?[]const u8 = null,
};

pub const StandardItem = struct {
    name: []const u8,
    version: []const u8 = "",
    size: i64 = 0,
    description: []const u8 = "",
    url: []const u8 = "",
    repository: []const u8 = "",
    replaces: []const []const u8 = &.{},
    licenses: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    depends: []const []const u8 = &.{},
    optional_depends: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    install_reason: []const u8 = "Unknown",
    install_date: ?i64 = null,
    build_date: i64 = 0,
    download_size: i64 = 0,
    installed_size: i64 = 0,
    required_by: []const []const u8 = &.{},
    optional_for: []const []const u8 = &.{},
};

pub const AppImageItem = struct {
    name: []const u8,
    desktop_name: []const u8 = "",
    version: []const u8 = "",
    icon_name: []const u8 = "",
    description: []const u8 = "",
    size_on_disk: u64 = 0,
    update_url: []const u8 = "",
    raw_update_info: []const u8 = "",
    repo_owner: ?[]const u8 = null,
    repo_name: ?[]const u8 = null,
    update_type: i32 = 0,
    allow_prerelease: bool = false,
    environment_variables: []const Zigalpm.appimage.environment.Variable = &.{},
    command_line_args: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const AurItem = struct {
    id: i64 = 0,
    name: []const u8,
    package_base_id: i64 = 0,
    package_base: []const u8 = "",
    version: []const u8 = "",
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    num_votes: i64 = 0,
    popularity: f64 = 0,
    out_of_date: ?i64 = null,
    maintainer: ?[]const u8 = null,
    first_submitted: i64 = 0,
    last_modified: i64 = 0,
    url_path: ?[]const u8 = null,
    depends: ?[]const []const u8 = null,
    make_depends: ?[]const []const u8 = null,
    optional_depends: ?[]const []const u8 = null,
    check_depends: ?[]const []const u8 = null,
    conflicts: ?[]const []const u8 = null,
    provides: ?[]const []const u8 = null,
    replaces: ?[]const []const u8 = null,
    groups: ?[]const []const u8 = null,
    licenses: ?[]const []const u8 = null,
    keywords: ?[]const []const u8 = null,
    required_by: ?[]const []const u8 = null,
    optional_for: ?[]const []const u8 = null,
    explicit: bool = false,
};

pub const FlatpakItem = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    branch: []const u8,
    latest_commit: []const u8 = "",
    summary: []const u8 = "",
    kind: i32 = 0,
    remote: []const u8 = "",
    install_level: i32 = 0,
    installed_size: u64 = 0,
    ref: []const u8 = "",
    full_ref: []const u8 = "",
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
    standard: ResultSet(StandardItem),
    appimage: ResultSet(AppImageItem),
    aur: ResultSet(AurItem),
    flatpak: ResultSet(FlatpakItem),

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .standard => |*result| result.deinit(allocator),
            .appimage => |*result| result.deinit(allocator),
            .aur => |*result| result.deinit(allocator),
            .flatpak => |*result| result.deinit(allocator),
        }
    }
};

const Real = struct {
    fn list(
        _: Real,
        context: *runtime.RuntimeContext,
        backend: Backend,
        options: ListOptions,
    ) !Result {
        return runReal(context, backend, options);
    }
};

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
    const backend = backendForPath(invocation.command.path) orelse return null;
    if (isFlatpakRemoteList(invocation))
        return try dispatchFlatpakRemote(context, invocation);
    var result = runner.list(
        context,
        backend,
        .{
            .show_hidden = optionEnabled(invocation, "--show-hidden"),
            .required_by = optionEnabled(invocation, "--required-by"),
            .optional_for = optionEnabled(invocation, "--optional-for"),
            .aur_url = aur_url.overrideValue(invocation),
        },
    ) catch |err| {
        try writeQueryFailure(context, invocation, backend, err);
        return 1;
    };
    defer result.deinit(context.allocator);

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeJson(context.allocator, &payload.writer, invocation, &result);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (invocation.globals.json) {
        try writeJson(context.allocator, context.stdout, invocation, &result);
        try context.stdout.writeByte('\n');
    } else {
        try writePlain(context, invocation, &result);
    }
    return 0;
}

fn isFlatpakRemoteList(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, flatpak_command_path) and
        invocation.positionals.len > 0 and
        std.mem.eql(u8, invocation.positionals[0], "remote");
}

fn dispatchFlatpakRemote(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    if (invocation.positionals.len == 1)
        return dispatchConfiguredFlatpakRemotes(context, invocation);

    const query = invocation.positionals[1];
    const get_all = std.ascii.eqlIgnoreCase(query, "all");
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();

    if (get_all) {
        const catalogs = manager.get_all_remote_appstreams(null) catch |err| {
            try writeRemoteQueryFailure(context, invocation, query, err);
            return 1;
        };
        defer Zigalpm.flatpak.AppstreamCatalog.deinitSlice(context.allocator, catalogs);
        return writeRemoteResult(context, invocation, catalogs, true);
    }

    var catalog = manager.get_remote_appstream(query, null) catch |err| {
        try writeRemoteQueryFailure(context, invocation, query, err);
        return 1;
    };
    defer catalog.deinit();
    return writeRemoteResult(context, invocation, &.{catalog}, false);
}

const ConfiguredRemote = struct {
    name: []const u8,
    scope: Zigalpm.flatpak.Scope,
    url: []const u8,
};

fn dispatchConfiguredFlatpakRemotes(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    const manager = Zigalpm.flatpak.RemoteManager{
        .allocator = context.allocator,
        .io = context.io,
    };
    const native_remotes = manager.listRemotesWithDetails() catch |err| {
        try writeConfiguredRemoteFailure(context, invocation, err);
        return 1;
    };
    defer Zigalpm.flatpak.Remote.deinitSlice(
        context.allocator,
        native_remotes,
    );
    const remotes = try context.allocator.alloc(ConfiguredRemote, native_remotes.len);
    defer context.allocator.free(remotes);
    for (native_remotes, remotes) |remote, *item| item.* = .{
        .name = remote.name,
        .scope = remote.scope,
        .url = remote.url,
    };

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeConfiguredRemotesJson(&payload.writer, remotes);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (invocation.globals.json) {
        try writeConfiguredRemotesJson(context.stdout, remotes);
        try context.stdout.writeByte('\n');
    } else {
        try writeConfiguredRemotesPlain(context, remotes);
    }
    return 0;
}

fn writeConfiguredRemoteFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    err: anyerror,
) !void {
    if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
        if (invocation.globals.ui_mode)
            try output.writeErrorFrame(context, message)
        else
            try output.writeFailure(context, message);
        return;
    }
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to list configured Flatpak remotes: {t}",
        .{err},
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try output.writeFailure(context, message);
}

fn writeConfiguredRemotesJson(
    writer: *std.Io.Writer,
    remotes: []const ConfiguredRemote,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (remotes) |remote| {
        try json.beginObject();
        try field(&json, "Name", remote.name);
        try field(&json, "Scope", @intFromEnum(remote.scope));
        try field(&json, "Url", remote.url);
        try json.endObject();
    }
    try json.endArray();
}

fn writeConfiguredRemotesPlain(
    context: *runtime.RuntimeContext,
    remotes: []const ConfiguredRemote,
) !void {
    const ansi = output.supportsAnsi(context);
    if (ansi)
        try context.stdout.print("{s}Remotes:{s}\n", .{ colors.colorCode(.heading), colors.reset })
    else
        try context.stdout.writeAll("Remotes:\n");
    for (remotes) |remote| {
        const scope = switch (remote.scope) {
            .system => "System",
            .user => "User",
            .unknown => "Unknown",
        };
        if (ansi) {
            const color: colors.Color = if (remote.scope == .system) .success else .warning;
            try context.stdout.print("{s} {s}({s}){s}\n", .{ remote.name, colors.colorCode(color), scope, colors.reset });
        } else {
            try context.stdout.print("{s} ({s})\n", .{ remote.name, scope });
        }
    }
}

fn writeRemoteQueryFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    query: []const u8,
    err: anyerror,
) !void {
    if (Zigalpm.flatpak.errors.unavailableMessage(err)) |message| {
        if (invocation.globals.ui_mode)
            try output.writeErrorFrame(context, message)
        else
            try output.writeFailure(context, message);
        return;
    }
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to read Flatpak AppStream catalog '{s}': {t}",
        .{ query, err },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try output.writeFailure(context, message);
}

fn writeRemoteResult(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    catalogs: []const Zigalpm.flatpak.AppstreamCatalog,
    merge_remotes: bool,
) !u8 {
    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeRemoteJson(context.allocator, &payload.writer, catalogs, merge_remotes);
        try output.writeFrame(context, payload.writer.buffered());
    } else {
        try writeRemoteJson(context.allocator, context.stdout, catalogs, merge_remotes);
        try context.stdout.writeByte('\n');
    }
    return 0;
}

const AppstreamRemote = struct {
    name: []const u8,
    scope: Zigalpm.flatpak.Scope,
};

const MergedAppstreamApp = struct {
    app: *const Zigalpm.flatpak.AppstreamApp,
    remotes: std.ArrayList(AppstreamRemote) = .empty,
};

fn writeRemoteJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    catalogs: []const Zigalpm.flatpak.AppstreamCatalog,
    merge_remotes: bool,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    if (!merge_remotes) {
        for (catalogs) |catalog| {
            for (catalog.apps) |*app| try writeAppstreamAppJson(&json, app, &.{});
        }
    } else {
        var indices: std.StringHashMapUnmanaged(usize) = .empty;
        defer indices.deinit(allocator);
        var apps: std.ArrayList(MergedAppstreamApp) = .empty;
        defer {
            for (apps.items) |*app| app.remotes.deinit(allocator);
            apps.deinit(allocator);
        }
        for (catalogs) |catalog| {
            for (catalog.apps) |*app| {
                if (indices.get(app.id)) |index| {
                    try apps.items[index].remotes.append(allocator, .{
                        .name = catalog.remote_name,
                        .scope = catalog.scope,
                    });
                    continue;
                }
                const index = apps.items.len;
                try apps.append(allocator, .{ .app = app });
                try apps.items[index].remotes.append(allocator, .{
                    .name = catalog.remote_name,
                    .scope = catalog.scope,
                });
                try indices.put(allocator, app.id, index);
            }
        }
        for (apps.items) |app| try writeAppstreamAppJson(&json, app.app, app.remotes.items);
    }
    try json.endArray();
}

fn writeAppstreamAppJson(
    json: *std.json.Stringify,
    app: *const Zigalpm.flatpak.AppstreamApp,
    remotes: []const AppstreamRemote,
) !void {
    try json.beginObject();
    try field(json, "Id", app.id);
    try field(json, "Name", app.name);
    try field(json, "Summary", app.summary);
    try field(json, "Description", app.description);
    try field(json, "Type", app.type);
    try field(json, "ProjectLicense", app.project_license);
    try field(json, "DeveloperName", app.developer_name);
    try field(json, "Categories", app.categories);
    try field(json, "Keywords", app.keywords);

    try json.objectField("Icons");
    try json.beginArray();
    for (app.icons) |icon| {
        try json.beginObject();
        try field(json, "Type", icon.type);
        try field(json, "Url", icon.url);
        try field(json, "Width", icon.width orelse 0);
        try field(json, "Height", icon.height orelse 0);
        try field(json, "Scale", icon.scale orelse 1);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("Screenshots");
    try json.beginArray();
    for (app.screenshots) |screenshot| {
        try json.beginObject();
        try field(json, "Caption", screenshot.caption);
        try field(json, "IsDefault", screenshot.is_default);
        try json.objectField("Images");
        try json.beginArray();
        for (screenshot.images) |appstream_image| {
            try json.beginObject();
            try field(json, "Type", appstream_image.type);
            try field(json, "Url", appstream_image.url);
            try field(json, "Width", appstream_image.width orelse 0);
            try field(json, "Height", appstream_image.height orelse 0);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("Releases");
    try json.beginArray();
    for (app.releases) |release| {
        try json.beginObject();
        try field(json, "Version", release.version);
        try field(json, "Type", release.type);
        try field(json, "Timestamp", release.timestamp orelse 0);
        try field(json, "Description", release.description);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("Urls");
    try json.beginObject();
    var url_iterator = app.urls.iterator();
    while (url_iterator.next()) |entry| {
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
    try json.endObject();
    try field(json, "IsVerified", app.is_verified);
    try field(json, "VerificationMethod", app.verification_method orelse "");

    try json.objectField("Remotes");
    try json.beginArray();
    for (remotes) |remote| {
        try json.beginObject();
        try field(json, "Name", remote.name);
        try field(json, "Scope", @intFromEnum(remote.scope));
        try field(json, "Url", "");
        try json.endObject();
    }
    try json.endArray();
    try field(json, "Extends", app.extends);

    try json.objectField("Addons");
    try json.beginArray();
    for (app.addons) |*addon| try writeAppstreamAppJson(json, addon, &.{});
    try json.endArray();
    try json.endObject();
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
        if (!std.mem.eql(u8, option.name, name)) continue;
        return option.value == null or !std.ascii.eqlIgnoreCase(option.value.?, "false");
    }
    return false;
}

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
            else if (invocation.globals.json)
                try context.stderr.print("{s}\n", .{message})
            else
                try output.writeFailure(context, message);
            return;
        }
    }
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to list installed {s} objects: {t}",
        .{ @tagName(backend), err },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else if (invocation.globals.json)
        try context.stderr.print("{s}\n", .{message})
    else
        try output.writeFailure(context, message);
}

fn writeJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    invocation: *const parser.Invocation,
    result: *const Result,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    switch (result.*) {
        .standard => |set| {
            const selected = try selectedStandard(allocator, invocation, set.items);
            defer allocator.free(selected);
            for (selected) |item| try writeStandardJson(&json, item);
        },
        .appimage => |set| for (set.items) |item| try writeAppImageJson(&json, item),
        .aur => |set| {
            const selected = try selectedAur(allocator, invocation, set.items);
            defer allocator.free(selected);
            for (selected) |item| try writeAurJson(&json, item);
        },
        .flatpak => |set| {
            const sorted = try sortedFlatpaks(allocator, set.items);
            defer allocator.free(sorted);
            for (sorted) |item| try writeFlatpakJson(&json, item);
        },
    }
    try json.endArray();
}

fn writeStandardJson(json: *std.json.Stringify, item: StandardItem) !void {
    try json.beginObject();
    try field(json, "Name", item.name);
    try field(json, "Version", item.version);
    try field(json, "Size", item.size);
    try field(json, "Description", item.description);
    try field(json, "Url", item.url);
    try field(json, "Repository", item.repository);
    try field(json, "Replaces", item.replaces);
    try field(json, "Licenses", item.licenses);
    try field(json, "Groups", item.groups);
    try field(json, "Provides", item.provides);
    try field(json, "Depends", item.depends);
    try field(json, "OptDepends", item.optional_depends);
    try field(json, "Conflicts", item.conflicts);
    try field(json, "PackageFile", null);
    try field(json, "InstallReason", item.install_reason);
    try json.objectField("InstallDate");
    if (item.install_date) |seconds| {
        var buffer: [32]u8 = undefined;
        try json.write(try formatIsoDateTime(&buffer, seconds));
    } else {
        try json.write(null);
    }
    try json.objectField("BuildDate");
    var build_date_buffer: [32]u8 = undefined;
    try json.write(try formatIsoDateTime(&build_date_buffer, item.build_date));
    try field(json, "DownloadSize", item.download_size);
    try field(json, "InstalledSize", item.installed_size);
    try field(json, "RequiredBy", item.required_by);
    try field(json, "OptionalFor", item.optional_for);
    try json.endObject();
}

fn writeAppImageJson(json: *std.json.Stringify, item: AppImageItem) !void {
    try json.beginObject();
    try field(json, "Name", item.name);
    try field(json, "DesktopName", item.desktop_name);
    try field(json, "Version", item.version);
    try field(json, "IconName", item.icon_name);
    try field(json, "Description", item.description);
    try field(json, "SizeOnDisk", item.size_on_disk);
    try field(json, "UpdateURl", item.update_url);
    try field(json, "RawUpdateInfo", item.raw_update_info);
    try field(json, "RepoOwner", item.repo_owner);
    try field(json, "RepoName", item.repo_name);
    try field(json, "UpdateType", item.update_type);
    try field(json, "AllowPrerelease", item.allow_prerelease);
    try json.objectField("EnvironmentVariables");
    try json.beginArray();
    for (item.environment_variables) |variable| {
        try json.beginObject();
        try field(json, "Key", variable.key);
        try field(json, "Value", variable.value);
        try json.endObject();
    }
    try json.endArray();
    try field(json, "CommandLineArgs", item.command_line_args);
    try field(json, "Path", item.path);
    try json.endObject();
}

fn writeAurJson(json: *std.json.Stringify, item: AurItem) !void {
    try json.beginObject();
    try field(json, "Id", item.id);
    try field(json, "Name", item.name);
    try field(json, "PackageBaseId", item.package_base_id);
    try field(json, "PackageBase", item.package_base);
    try field(json, "Version", item.version);
    try field(json, "Description", item.description);
    try field(json, "Url", item.url);
    try field(json, "NumVotes", item.num_votes);
    try field(json, "Popularity", item.popularity);
    try field(json, "OutOfDate", item.out_of_date);
    try field(json, "Maintainer", item.maintainer);
    try field(json, "FirstSubmitted", item.first_submitted);
    try field(json, "LastModified", item.last_modified);
    try field(json, "UrlPath", item.url_path);
    try field(json, "Depends", item.depends);
    try field(json, "MakeDepends", item.make_depends);
    try field(json, "OptDepends", item.optional_depends);
    try field(json, "CheckDepends", item.check_depends);
    try field(json, "Conflicts", item.conflicts);
    try field(json, "Provides", item.provides);
    try field(json, "Replaces", item.replaces);
    try field(json, "Groups", item.groups);
    try field(json, "License", item.licenses);
    try field(json, "Keywords", item.keywords);
    try field(json, "RequiredBy", item.required_by);
    try field(json, "OptionalFor", item.optional_for);
    try field(json, "Explicit", item.explicit);
    try json.endObject();
}

fn writeFlatpakJson(json: *std.json.Stringify, item: FlatpakItem) !void {
    const empty_list: []const []const u8 = &.{};
    try json.beginObject();
    try field(json, "Id", item.id);
    try field(json, "Name", item.name);
    try field(json, "Version", item.version);
    try field(json, "Arch", item.arch);
    try field(json, "Branch", item.branch);
    try field(json, "LatestCommit", item.latest_commit);
    try field(json, "Summary", item.summary);
    try field(json, "Kind", item.kind);
    try field(json, "IconPath", null);
    try field(json, "Description", "");
    try field(json, "Releases", empty_list);
    try field(json, "Categories", empty_list);
    try field(json, "Remote", item.remote);
    try field(json, "InstallLevel", item.install_level);
    try field(json, "Permissions", empty_list);
    try field(json, "InstalledSize", item.installed_size);
    try field(json, "Ref", item.ref);
    try field(json, "FullRef", item.full_ref);
    try field(json, "Eol", item.eol);
    try field(json, "EolRebase", item.eol_rebase);
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn writePlain(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    result: *const Result,
) !void {
    switch (result.*) {
        .standard => |set| try writeStandardPlain(context, invocation, set.items),
        .appimage => |set| try writeAppImagePlain(context, set.items),
        .aur => |set| try writeAurPlain(context, invocation, set.items),
        .flatpak => |set| try writeFlatpakPlain(context, set.items),
    }
}

fn writeStandardPlain(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    items: []const StandardItem,
) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const selected = try selectedStandard(allocator, invocation, items);
    const rows = try allocator.alloc([]const []const u8, selected.len);
    const size_display = try loadSizeDisplay(context);
    const include_required_by = optionEnabled(invocation, "--required-by");
    const include_optional_for = optionEnabled(invocation, "--optional-for");
    var headings: std.ArrayList([]const u8) = .empty;
    try headings.appendSlice(allocator, &.{ "Name", "Repository", "Version", "Size", "Description" });
    if (include_required_by) try headings.append(allocator, "Required By");
    if (include_optional_for) try headings.append(allocator, "Optional For");
    for (selected, rows) |item, *cells| {
        var values: std.ArrayList([]const u8) = .empty;
        try values.appendSlice(allocator, &.{
            item.name,
            item.repository,
            item.version,
            try formatSignedSize(allocator, size_display, item.installed_size),
            truncate(item.description, 50),
        });
        if (include_required_by)
            try values.append(allocator, try joinedNames(allocator, item.required_by));
        if (include_optional_for)
            try values.append(allocator, try joinedNames(allocator, item.optional_for));
        cells.* = try values.toOwnedSlice(allocator);
    }
    try table.write(
        context,
        headings.items,
        rows,
    );
    try coloredTotal(context, try std.fmt.allocPrint(allocator, "Total: {d} packages", .{selected.len}));
}

fn writeAppImagePlain(context: *runtime.RuntimeContext, items: []const AppImageItem) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const rows = try allocator.alloc([]const []const u8, items.len);
    const size_display = try loadSizeDisplay(context);
    for (items, rows) |item, *cells| {
        const update_info = if (item.update_url.len != 0)
            item.update_url
        else if (item.repo_owner) |owner|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, item.repo_name orelse "" })
        else
            "";
        cells.* = try row(allocator, &.{
            item.name,
            item.version,
            try formatSize(allocator, size_display, item.size_on_disk),
            update_info,
        });
    }
    try table.write(
        context,
        &.{ "Name", "Version", "Size", "Update Info" },
        rows,
    );
}

fn writeAurPlain(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    items: []const AurItem,
) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const selected = try selectedAur(allocator, invocation, items);
    const rows = try allocator.alloc([]const []const u8, selected.len);
    const include_required_by = optionEnabled(invocation, "--required-by");
    const include_optional_for = optionEnabled(invocation, "--optional-for");
    var headings: std.ArrayList([]const u8) = .empty;
    try headings.appendSlice(allocator, &.{ "Name", "Version", "Description" });
    if (include_required_by) try headings.append(allocator, "Required By");
    if (include_optional_for) try headings.append(allocator, "Optional For");
    for (selected, rows) |item, *cells| {
        var values: std.ArrayList([]const u8) = .empty;
        try values.appendSlice(allocator, &.{
            item.name,
            item.version,
            truncate(item.description orelse "", 60),
        });
        if (include_required_by)
            try values.append(allocator, try joinedNames(allocator, item.required_by orelse &.{}));
        if (include_optional_for)
            try values.append(allocator, try joinedNames(allocator, item.optional_for orelse &.{}));
        cells.* = try values.toOwnedSlice(allocator);
    }
    try table.write(
        context,
        headings.items,
        rows,
    );
    try coloredTotal(context, try std.fmt.allocPrint(
        allocator,
        "Total: {d} AUR packages installed",
        .{selected.len},
    ));
}

fn writeFlatpakPlain(context: *runtime.RuntimeContext, items: []const FlatpakItem) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const sorted = try sortedFlatpaks(allocator, items);
    const rows = try allocator.alloc([]const []const u8, sorted.len);
    for (sorted, rows) |item, *cells| cells.* = try row(allocator, &.{
        item.name,
        item.id,
        item.version,
        item.arch,
        item.branch,
        truncate(item.summary, 50),
        item.remote,
    });
    try table.write(
        context,
        &.{ "Name", "Id", "Version", "Arch", "Branch", "Summary", "Remote" },
        rows,
    );
    try coloredTotal(context, try std.fmt.allocPrint(allocator, "Total: {d} packages", .{sorted.len}));
}

fn coloredTotal(context: *runtime.RuntimeContext, message: []const u8) !void {
    try colors.printLine(context, .heading, "{s}", .{message});
}

fn row(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    @memcpy(result, values);
    return result;
}

fn joinedNames(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, ", ", values);
}

fn selectedAur(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
    items: []const AurItem,
) ![]AurItem {
    const explicit_only = optionEnabled(invocation, "--explicitOnly");
    const dependency_only = optionEnabled(invocation, "--dependencyOnly");
    var selected: std.ArrayList(AurItem) = .empty;
    for (items) |item| {
        if (explicit_only and !dependency_only and !item.explicit) continue;
        if (dependency_only and !explicit_only and item.explicit) continue;
        try selected.append(allocator, item);
    }
    std.mem.sort(AurItem, selected.items, {}, struct {
        fn lessThan(_: void, left: AurItem, right: AurItem) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn selectedStandard(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
    items: []const StandardItem,
) ![]StandardItem {
    const explicit_only = optionEnabled(invocation, "--explicitOnly");
    const dependency_only = optionEnabled(invocation, "--dependencyOnly");
    var selected: std.ArrayList(StandardItem) = .empty;
    for (items) |item| {
        const explicitly_installed = std.mem.eql(u8, item.install_reason, "Explicit");
        const dependency_installed = std.mem.eql(u8, item.install_reason, "Dependency");
        if (explicit_only and !dependency_only and !explicitly_installed) continue;
        if (dependency_only and !explicit_only and !dependency_installed) continue;
        try selected.append(allocator, item);
    }
    std.mem.sort(StandardItem, selected.items, {}, struct {
        fn lessThan(_: void, left: StandardItem, right: StandardItem) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn sortedFlatpaks(allocator: std.mem.Allocator, items: []const FlatpakItem) ![]FlatpakItem {
    const sorted = try allocator.dupe(FlatpakItem, items);
    std.mem.sort(FlatpakItem, sorted, {}, struct {
        fn lessThan(_: void, left: FlatpakItem, right: FlatpakItem) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
    return sorted;
}

const SizeDisplay = format.SizeDisplay;
const loadSizeDisplay = format.loadSizeDisplay;
const formatSize = format.formatSize;
const formatIsoDateTime = format.formatIsoDateTime;

fn formatSignedSize(allocator: std.mem.Allocator, display: SizeDisplay, bytes: i64) ![]const u8 {
    return formatSize(allocator, display, if (bytes <= 0) 0 else @intCast(bytes));
}

fn truncate(value: []const u8, maximum: usize) []const u8 {
    return format.truncate(value, maximum);
}

fn runReal(
    context: *runtime.RuntimeContext,
    backend: Backend,
    options: ListOptions,
) !Result {
    return switch (backend) {
        .standard => runStandard(context, options),
        .appimage => runAppImage(context),
        .aur => runAur(context, options),
        .flatpak => runFlatpak(context),
    };
}

fn runStandard(context: *runtime.RuntimeContext, options: ListOptions) !Result {
    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        .{ .use_root = false },
    );
    defer manager.deinit();
    if (options.show_hidden and !manager.show_hidden_packages) _ = manager.toggle_hidden_packages();
    const native_items = try manager.get_installed_packages_with_reverse_dependencies(.{
        .required_by = options.required_by,
        .optional_for = options.optional_for,
    });
    defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    var items: std.ArrayList(StandardItem) = .empty;
    for (native_items) |native| {
        const name = native.name() orelse continue;
        if (!options.show_hidden and ignoredStandardPackage(manager, name)) continue;
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, native.version() orelse ""),
            .size = native.download_size(),
            .description = try allocator.dupe(u8, native.description() orelse ""),
            .url = try allocator.dupe(u8, native.url() orelse ""),
            .repository = try allocator.dupe(u8, native.repository() orelse ""),
            .replaces = try copyStrings(allocator, native.replaces()),
            .licenses = try copyStrings(allocator, native.licenses()),
            .groups = try copyStrings(allocator, native.groups()),
            .provides = try copyStrings(allocator, native.provides()),
            .depends = try copyStrings(allocator, native.depends()),
            .optional_depends = try copyStrings(allocator, native.optional_depends()),
            .conflicts = try copyStrings(allocator, native.conflicts()),
            .install_reason = @tagName(native.install_reason()),
            .install_date = native.install_date(),
            .build_date = native.build_date(),
            .download_size = native.download_size(),
            .installed_size = native.install_size(),
            .required_by = try copyStrings(allocator, native.required_by()),
            .optional_for = try copyStrings(allocator, native.optional_for()),
        });
    }
    return .{ .standard = .{ .items = try items.toOwnedSlice(allocator), .arena = arena } };
}

fn runAppImage(context: *runtime.RuntimeContext) !Result {
    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    defer context.allocator.free(local_db_path);
    var manager = Zigalpm.AppImageManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    const native_items = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    const items = try allocator.alloc(AppImageItem, native_items.len);
    for (native_items, items) |native, *item| item.* = .{
        .name = try allocator.dupe(u8, native.name),
        .desktop_name = try allocator.dupe(u8, native.desktop_name),
        .version = try allocator.dupe(u8, native.version),
        .icon_name = try allocator.dupe(u8, native.icon_name),
        .description = try allocator.dupe(u8, native.description),
        .size_on_disk = native.size_on_disk,
        .update_url = try allocator.dupe(u8, native.update_url),
        .raw_update_info = try allocator.dupe(u8, native.raw_update_info),
        .repo_owner = try copyOptionalString(allocator, native.repo_owner),
        .repo_name = try copyOptionalString(allocator, native.repo_name),
        .update_type = @intCast(@intFromEnum(native.update_type)),
        .allow_prerelease = native.allow_prerelease,
        .environment_variables = try Zigalpm.appimage.environment.clone(allocator, native.environment_variables),
        .command_line_args = try allocator.dupe(u8, native.command_line_args),
        .path = try allocator.dupe(u8, native.path),
    };
    return .{ .appimage = .{ .items = items, .arena = arena } };
}

fn runAur(context: *runtime.RuntimeContext, options: ListOptions) !Result {
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
    const native_items = try manager.getInstalledPackagesWithReverseDependencies(.{
        .required_by = options.required_by,
        .optional_for = options.optional_for,
    });
    defer Zigalpm.aur.models.Package.deinitSlice(context.allocator, native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    const items = try allocator.alloc(AurItem, native_items.len);
    for (native_items, items) |native, *item| item.* = .{
        .id = native.id,
        .name = try allocator.dupe(u8, native.name),
        .package_base_id = native.package_base_id,
        .package_base = try allocator.dupe(u8, native.package_base),
        .version = try allocator.dupe(u8, native.version),
        .description = try copyOptionalString(allocator, native.description),
        .url = try copyOptionalString(allocator, native.url),
        .num_votes = native.num_votes,
        .popularity = native.popularity,
        .out_of_date = native.out_of_date,
        .maintainer = try copyOptionalString(allocator, native.maintainer),
        .first_submitted = native.first_submitted,
        .last_modified = native.last_modified,
        .url_path = try copyOptionalString(allocator, native.url_path),
        .depends = try copyOptionalStrings(allocator, native.depends),
        .make_depends = try copyOptionalStrings(allocator, native.make_depends),
        .optional_depends = try copyOptionalStrings(allocator, native.opt_depends),
        .check_depends = try copyOptionalStrings(allocator, native.check_depends),
        .conflicts = try copyOptionalStrings(allocator, native.conflicts),
        .provides = try copyOptionalStrings(allocator, native.provides),
        .replaces = try copyOptionalStrings(allocator, native.replaces),
        .groups = try copyOptionalStrings(allocator, native.groups),
        .licenses = try copyOptionalStrings(allocator, native.licenses),
        .keywords = try copyOptionalStrings(allocator, native.keywords),
        .required_by = try copyOptionalStrings(allocator, native.required_by),
        .optional_for = try copyOptionalStrings(allocator, native.optional_for),
        .explicit = native.explicit,
    };
    return .{ .aur = .{ .items = items, .arena = arena } };
}

fn runFlatpak(context: *runtime.RuntimeContext) !Result {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    const native_items = try manager.list_installed_applications();
    defer Zigalpm.flatpak.manager.InstalledApplication.deinitSlice(context.allocator, native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    const items = try allocator.alloc(FlatpakItem, native_items.len);
    for (native_items, items) |native, *item| {
        const kind = if (native.kind == .app) "app" else "runtime";
        const ref = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}",
            .{ kind, native.id, native.arch, native.branch },
        );
        item.* = .{
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
            .installed_size = native.installed_size,
            .ref = ref,
            .full_ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ native.origin, ref }),
            .eol = if (native.eol) |value| try allocator.dupe(u8, value) else "",
            .eol_rebase = if (native.eol_rebase) |value| try allocator.dupe(u8, value) else "",
        };
    }
    return .{ .flatpak = .{ .items = items, .arena = arena } };
}

fn createArena(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    allocator.destroy(arena);
}

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn copyOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn copyOptionalStrings(
    allocator: std.mem.Allocator,
    values: ?[]const []const u8,
) !?[]const []const u8 {
    const source = values orelse return null;
    const copies = try allocator.alloc([]const u8, source.len);
    for (source, copies) |value, *copy| copy.* = try allocator.dupe(u8, value);
    return copies;
}

fn copyStrings(allocator: std.mem.Allocator, values: anytype) ![]const []const u8 {
    const copies = try allocator.alloc([]const u8, values.len);
    for (values, copies) |value, *copy| copy.* = try allocator.dupe(u8, value);
    return copies;
}

fn ignoredStandardPackage(manager: *Zigalpm.AlpmManager, name: []const u8) bool {
    for (manager.config.ignore_package.items) |ignored| {
        if (std.mem.eql(u8, ignored, name)) return true;
    }
    return false;
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

test "list routes long and requested uppercase short forms to package backends only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const Case = struct { arguments: []const []const u8, backend: Backend };
    const cases = [_]Case{
        .{ .arguments = &.{ "list", "standard" }, .backend = .standard },
        .{ .arguments = &.{"-Ls"}, .backend = .standard },
        .{ .arguments = &.{ "list", "appimage" }, .backend = .appimage },
        .{ .arguments = &.{"-LI"}, .backend = .appimage },
        .{ .arguments = &.{ "list", "aur" }, .backend = .aur },
        .{ .arguments = &.{"-LA"}, .backend = .aur },
        .{ .arguments = &.{ "list", "flatpak" }, .backend = .flatpak },
        .{ .arguments = &.{"-LF"}, .backend = .flatpak },
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
        const Observed = struct {
            backend: ?Backend = null,

            fn list(self: *@This(), _: *runtime.RuntimeContext, backend: Backend, _: ListOptions) !Result {
                self.backend = backend;
                return switch (backend) {
                    .standard => .{ .standard = .{ .items = &.{} } },
                    .appimage => .{ .appimage = .{ .items = &.{} } },
                    .aur => .{ .aur = .{ .items = &.{} } },
                    .flatpak => .{ .flatpak = .{ .items = &.{} } },
                };
            }
        };
        var observed: Observed = .{};
        try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, &observed));
        try std.testing.expectEqual(case.backend, observed.backend.?);
    }

    const uppercase_standard = try shortcodes.translate(arena.allocator(), &manifest, &.{"-LS"});
    try std.testing.expect(uppercase_standard == .failure);
    try std.testing.expect(std.mem.indexOf(u8, uppercase_standard.failure, "Unknown shortcode type 'S'") != null);

    const keyring = try parseTestArguments(arena.allocator(), &manifest, &.{ "list", "keyring" });
    try std.testing.expect(keyring == .failure);
}

test "list reverse dependency modifiers are selective and backend scoped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const Case = struct {
        arguments: []const []const u8,
        backend: Backend,
        required_by: bool = false,
        optional_for: bool = false,
    };
    const cases = [_]Case{
        .{ .arguments = &.{ "list", "standard", "--json" }, .backend = .standard },
        .{
            .arguments = &.{ "list", "standard", "--required-by", "--json" },
            .backend = .standard,
            .required_by = true,
        },
        .{
            .arguments = &.{ "list", "aur", "--optional-for", "--json" },
            .backend = .aur,
            .optional_for = true,
        },
        .{
            .arguments = &.{ "list", "aur", "--required-by", "--optional-for", "--json" },
            .backend = .aur,
            .required_by = true,
            .optional_for = true,
        },
    };
    for (cases) |case| {
        const Capture = struct {
            expected: Case,
            called: bool = false,

            fn list(self: *@This(), _: *runtime.RuntimeContext, backend: Backend, options: ListOptions) !Result {
                try std.testing.expectEqual(self.expected.backend, backend);
                try std.testing.expectEqual(self.expected.required_by, options.required_by);
                try std.testing.expectEqual(self.expected.optional_for, options.optional_for);
                self.called = true;
                return switch (backend) {
                    .standard => .{ .standard = .{ .items = &.{} } },
                    .appimage => .{ .appimage = .{ .items = &.{} } },
                    .aur => .{ .aur = .{ .items = &.{} } },
                    .flatpak => .{ .flatpak = .{ .items = &.{} } },
                };
            }
        };
        var capture = Capture{ .expected = case };
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
        try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, &capture));
        try std.testing.expect(capture.called);
    }

    const appimage = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "appimage", "--required-by" },
    );
    try std.testing.expect(appimage == .failure);
    const flatpak = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "flatpak", "--optional-for" },
    );
    try std.testing.expect(flatpak == .failure);
}

test "standard install-reason filters apply to structured output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const items = [_]StandardItem{
        .{ .name = "dependency-package", .version = "1", .install_reason = "Dependency" },
        .{
            .name = "explicit-package",
            .version = "2",
            .install_reason = "Explicit",
            .required_by = &.{"desktop-meta"},
            .optional_for = &.{"shell-extras"},
        },
    };
    const Fixture = struct {
        values: *const [2]StandardItem,

        fn list(self: @This(), _: *runtime.RuntimeContext, _: Backend, options: ListOptions) !Result {
            try std.testing.expect(options.show_hidden);
            return .{ .standard = .{ .items = self.values } };
        }
    };
    const fixture = Fixture{ .values = &items };
    const outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "-Lswe", "--json" },
    );
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &outcome.dispatch, fixture));
    const rendered = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "explicit-package") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "dependency-package") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"PackageFile\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"InstallReason\":\"Explicit\"") != null);

    tc.stdout.writer.end = 0;
    const plain_outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "list", "standard", "--show-hidden", "--required-by", "--optional-for" },
    );
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &plain_outcome.dispatch, fixture));
    const plain = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain, "Required By") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Optional For") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "desktop-meta") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "shell-extras") != null);
}

test "AUR filters apply to JSON and UI structured output" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const items = [_]AurItem{
        .{ .name = "dependency-package", .version = "1", .explicit = false },
        .{
            .name = "explicit-package",
            .version = "2",
            .required_by = &.{"desktop-meta"},
            .optional_for = &.{"shell-extras"},
            .explicit = true,
        },
    };
    const Fixture = struct {
        values: *const [2]AurItem,

        fn list(self: @This(), _: *runtime.RuntimeContext, _: Backend, _: ListOptions) !Result {
            return .{ .aur = .{ .items = self.values } };
        }
    };
    const fixture = Fixture{ .values = &items };

    const json_outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "list", "aur", "--explicitOnly", "--required-by", "--optional-for", "--json" },
    );
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &json_outcome.dispatch, fixture));
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "explicit-package") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "dependency-package") == null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "\"RequiredBy\":[\"desktop-meta\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "\"OptionalFor\":[\"shell-extras\"]") != null);

    tc.stdout.writer.end = 0;
    const ui_outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "list", "aur", "--dependencyOnly", "--ui-mode" },
    );
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &ui_outcome.dispatch, fixture));
    const payload = try decodeFirstTestFrame(tc.arena.allocator(), tc.stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, payload, "dependency-package") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "explicit-package") == null);

    tc.stdout.writer.end = 0;
    const plain_outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "list", "aur", "--required-by", "--optional-for" },
    );
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&tc.context, &plain_outcome.dispatch, fixture));
    const plain = tc.stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain, "Required By") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Optional For") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "desktop-meta") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "shell-extras") != null);
}

test "AppImage and Flatpak lists emit compatibility JSON and stable ordering" {
    var output_buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_buffer.deinit();
    const appimages = [_]AppImageItem{.{
        .name = "Editor",
        .version = "3.0",
        .size_on_disk = 4096,
        .update_type = 2,
        .environment_variables = &.{.{ .key = "WEBKIT_DISABLE_DMABUF_RENDERER", .value = "1" }},
        .command_line_args = "--safe",
        .path = "/apps/editor.AppImage",
    }};
    const app_result: Result = .{ .appimage = .{ .items = &appimages } };
    var app_invocation: parser.Invocation = undefined;
    app_invocation.options = &.{};
    try writeJson(std.testing.allocator, &output_buffer.writer, &app_invocation, &app_result);
    try std.testing.expect(std.mem.indexOf(u8, output_buffer.writer.buffered(), "\"UpdateURl\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buffer.writer.buffered(), "\"UpdateType\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buffer.writer.buffered(), "\"EnvironmentVariables\":[{\"Key\":\"WEBKIT_DISABLE_DMABUF_RENDERER\",\"Value\":\"1\"}]") != null);

    output_buffer.writer.end = 0;
    const flatpaks = [_]FlatpakItem{
        .{ .id = "z.app", .name = "Z", .version = "1", .arch = "x86_64", .branch = "stable" },
        .{ .id = "a.app", .name = "A", .version = "2", .arch = "x86_64", .branch = "stable" },
    };
    const flatpak_result: Result = .{ .flatpak = .{ .items = &flatpaks } };
    try writeJson(std.testing.allocator, &output_buffer.writer, &app_invocation, &flatpak_result);
    const rendered = output_buffer.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a.app").? < std.mem.indexOf(u8, rendered, "z.app").?);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Permissions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"InstallLevel\":0") != null);
}

test "Flatpak list renders EOL fields in JSON output" {
    var output_buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_buffer.deinit();
    var invocation: parser.Invocation = undefined;
    invocation.options = &.{};

    const flatpaks = [_]FlatpakItem{
        .{
            .id = "dev.bragefuglseth.Keypunch",
            .name = "Keypunch",
            .version = "1.0",
            .arch = "x86_64",
            .branch = "stable",
            .eol = "Deprecated.",
            .eol_rebase = "no.bragefuglseth.Keypunch",
        },
        .{
            .id = "org.example.Dead",
            .name = "Dead",
            .version = "2.0",
            .arch = "x86_64",
            .branch = "stable",
            .eol = "No longer maintained",
        },
        .{
            .id = "org.example.Alive",
            .name = "Alive",
            .version = "3.0",
            .arch = "x86_64",
            .branch = "stable",
        },
    };
    const result: Result = .{ .flatpak = .{ .items = &flatpaks } };
    try writeJson(std.testing.allocator, &output_buffer.writer, &invocation, &result);
    const rendered = output_buffer.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Eol\":\"Deprecated.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"EolRebase\":\"no.bragefuglseth.Keypunch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Eol\":\"No longer maintained\"") != null);
    // Non-EOL refs emit empty EOL fields rather than null.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Eol\":\"\"") != null);
}

test "Flatpak remote mode parses configured remotes and AppStream queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    var outcome = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "flatpak", "remote" },
    );
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isFlatpakRemoteList(&outcome.dispatch));
    try std.testing.expectEqual(@as(usize, 1), outcome.dispatch.positionals.len);

    outcome = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "flatpak", "remote", "flathub" },
    );
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(isFlatpakRemoteList(&outcome.dispatch));
    try std.testing.expectEqualStrings("flathub", outcome.dispatch.positionals[1]);

    const invalid = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "flatpak", "installed" },
    );
    try std.testing.expect(invalid == .failure);
}

test "configured Flatpak remotes use compatibility JSON fields and scopes" {
    const remotes = [_]ConfiguredRemote{
        .{ .name = "flathub", .scope = .system, .url = "https://dl.flathub.org/repo/" },
        .{ .name = "flathub-beta", .scope = .user, .url = "https://flathub.org/beta-repo/" },
    };
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();
    try writeConfiguredRemotesJson(&rendered.writer, &remotes);
    const json = rendered.writer.buffered();
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"Name\":\"flathub\",\"Scope\":0,\"Url\":\"https://dl.flathub.org/repo/\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"Name\":\"flathub-beta\",\"Scope\":1,\"Url\":\"https://flathub.org/beta-repo/\"",
    ) != null);
}

test "Flatpak all-remote AppStream JSON merges IDs and records scopes" {
    var first_apps = [_]Zigalpm.flatpak.AppstreamApp{.{
        .type = "desktop-application",
        .id = "org.example.App",
        .name = "Example",
        .summary = "First catalog",
        .project_license = "MIT",
        .developer_name = "Example Org",
        .extends = null,
        .description = "An example application",
        .categories = &.{"Utility"},
        .keywords = &.{"example"},
        .urls = .empty,
        .icons = &.{.{ .type = "cached", .url = "icon.png" }},
        .screenshots = &.{},
        .releases = &.{},
        .is_verified = false,
        .verification_method = null,
        .addons = &.{},
    }};
    var second_apps = [_]Zigalpm.flatpak.AppstreamApp{first_apps[0]};
    second_apps[0].summary = "Second catalog";
    const catalogs = [_]Zigalpm.flatpak.AppstreamCatalog{
        .{
            .owner_allocator = std.testing.allocator,
            .arena_state = undefined,
            .remote_name = "flathub",
            .scope = .system,
            .arch = "x86_64",
            .path = "",
            .apps = &first_apps,
        },
        .{
            .owner_allocator = std.testing.allocator,
            .arena_state = undefined,
            .remote_name = "flathub-user",
            .scope = .user,
            .arch = "x86_64",
            .path = "",
            .apps = &second_apps,
        },
    };
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();
    try writeRemoteJson(std.testing.allocator, &rendered.writer, &catalogs, true);
    const json = rendered.writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\"Id\":\"org.example.App\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Name\":\"flathub\",\"Scope\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Name\":\"flathub-user\",\"Scope\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Width\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Scale\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"VerificationMethod\":\"\"") != null);
}

test "Flatpak named-remote AppStream JSON uses UI framing" {
    var apps = [_]Zigalpm.flatpak.AppstreamApp{.{
        .type = "desktop-application",
        .id = "org.example.App",
        .name = "Example",
        .summary = "Example summary",
        .project_license = "",
        .developer_name = "",
        .extends = null,
        .description = "",
        .categories = &.{},
        .keywords = &.{},
        .urls = .empty,
        .icons = &.{},
        .screenshots = &.{},
        .releases = &.{},
        .is_verified = false,
        .verification_method = null,
        .addons = &.{},
    }};
    const catalogs = [_]Zigalpm.flatpak.AppstreamCatalog{.{
        .owner_allocator = std.testing.allocator,
        .arena_state = undefined,
        .remote_name = "flathub",
        .scope = .system,
        .arch = "x86_64",
        .path = "",
        .apps = &apps,
    }};
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parseTestArguments(
        tc.arena.allocator(),
        &manifest,
        &.{ "list", "flatpak", "remote", "flathub", "--ui-mode" },
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        try writeRemoteResult(&tc.context, &outcome.dispatch, &catalogs, false),
    );
    const payload = try decodeFirstTestFrame(tc.arena.allocator(), tc.stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"Id\":\"org.example.App\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"Remotes\":[]") != null);
}
