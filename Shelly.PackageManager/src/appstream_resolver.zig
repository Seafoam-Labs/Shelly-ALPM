//! Read-only AppStream identity resolution. All returned data belongs to the caller's arena.
const std = @import("std");
const xml = @import("zig-xml");
const Native = @import("alpm/manager.zig").Manager;
const Flatpak = @import("flatpak/manager.zig").Manager;
const fp = @import("flatpak/types.zig");

pub const Candidate = struct {
    source: enum { native, flatpak },
    id: []const u8,
    name: []const u8,
    installed: bool,
    summary: []const u8 = "",
    remote: []const u8 = "",
    scope: []const u8 = "",
    ref: []const u8 = "",
};
pub const Problem = struct { source: []const u8, code: []const u8 };
pub const Result = struct {
    candidates: []const Candidate,
    problems: []const Problem,
};

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or id[0] == '.') return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}

pub fn resolve(a: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Native.InitOptions, id: []const u8, include_flatpak: bool) !Result {
    if (!validId(id)) return error.InvalidComponentId;
    var candidates: std.ArrayList(Candidate) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    resolveNative(a, io, environ, options, id, &candidates) catch |err| {
        if (err == error.OutOfMemory) return err;
        try problems.append(a, .{ .source = "native", .code = @errorName(err) });
    };
    if (include_flatpak) resolveFlatpak(a, io, id, &candidates) catch |err| {
        if (err == error.OutOfMemory) return err;
        try problems.append(a, .{ .source = "flatpak", .code = @errorName(err) });
    };
    return .{ .candidates = try candidates.toOwnedSlice(a), .problems = try problems.toOwnedSlice(a) };
}

fn resolveNative(a: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Native.InitOptions, id: []const u8, candidates: *std.ArrayList(Candidate)) !void {
    const manager = try Native.init(a, environ, options);
    defer manager.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    try addDesktopPaths(a, &paths, id);
    var metadata_failed = false;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    for ([_][]const u8{ "usr/share/metainfo", "usr/share/appdata", "usr/local/share/metainfo", "usr/local/share/appdata" }) |relative_dir| {
        const directory = try std.fs.path.join(a, &.{ manager.config.root_directory, relative_dir });
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".xml")) continue;
            _ = scratch.reset(.retain_capacity);
            const bytes = dir.readFileAlloc(io, entry.name, scratch.allocator(), .limited(4 * 1024 * 1024)) catch {
                metadata_failed = true;
                continue;
            };
            const metadata = parseMetadata(scratch.allocator(), bytes) catch {
                metadata_failed = true;
                continue;
            };
            if (!std.mem.eql(u8, metadata.id, id)) continue;
            try paths.append(a, try std.fs.path.join(a, &.{ relative_dir, entry.name }));
            for (metadata.desktops) |desktop| try addDesktopPaths(a, &paths, desktop);
        }
    }
    const owners = try manager.get_file_owners(paths.items);
    defer Native.OwnedPackage.deinitSlice(a, owners);
    for (owners) |owner| try candidates.append(a, .{
        .source = .native,
        .id = try a.dupe(u8, owner.name_value),
        .name = try a.dupe(u8, owner.name_value),
        .summary = try a.dupe(u8, owner.description_value orelse ""),
        .installed = true,
    });
    if (metadata_failed and owners.len == 0) return error.AppstreamMetadataUnreadable;
}

fn addDesktopPaths(a: std.mem.Allocator, paths: *std.ArrayList([]const u8), id: []const u8) !void {
    if (!validId(id)) return;
    const suffix = if (std.mem.endsWith(u8, id, ".desktop")) "" else ".desktop";
    for ([_][]const u8{ "usr/share/applications", "usr/local/share/applications" }) |dir|
        try paths.append(a, try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ dir, id, suffix }));
}

const Metadata = struct { id: []const u8 = "", desktops: []const []const u8 = &.{} };
fn parseMetadata(a: std.mem.Allocator, bytes: []const u8) !Metadata {
    var static: xml.Reader.Static = .init(a, bytes, .{});
    defer static.deinit();
    const reader = &static.interface;
    var result: Metadata = .{};
    var desktops: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var component_depth: ?usize = null;
    while (true) switch (try reader.read()) {
        .eof => break,
        .element_start => {
            depth += 1;
            const name = reader.elementName();
            if (std.mem.eql(u8, name, "component") or std.mem.eql(u8, name, "application")) component_depth = depth;
            if (component_depth == null or depth != component_depth.? + 1) continue;
            if (std.mem.eql(u8, name, "id")) {
                result.id = try elementText(a, reader);
                depth -= 1;
            } else if (std.mem.eql(u8, name, "launchable")) {
                const index = reader.attributeIndex("type") orelse continue;
                if (!std.mem.eql(u8, try reader.attributeValue(index), "desktop-id")) continue;
                try desktops.append(a, try elementText(a, reader));
                depth -= 1;
            }
        },
        .element_end => {
            if (component_depth == depth) component_depth = null;
            depth -= 1;
        },
        else => {},
    };
    result.desktops = try desktops.toOwnedSlice(a);
    return result;
}
fn elementText(a: std.mem.Allocator, reader: *xml.Reader) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var depth: usize = 1;
    while (depth > 0) switch (try reader.read()) {
        .eof => return error.UnexpectedEndOfStream,
        .element_start => depth += 1,
        .element_end => depth -= 1,
        .text => try reader.textWrite(&out.writer),
        .cdata => try reader.cdataWrite(&out.writer),
        .character_reference => try out.writer.print("{u}", .{reader.characterReferenceChar()}),
        .entity_reference => try out.writer.writeAll(xml.predefined_entities.get(reader.entityReferenceName()) orelse return error.UnknownEntity),
        else => {},
    };
    return std.mem.trim(u8, try out.toOwnedSlice(), " \r\n\t");
}

pub fn matchesFlatpak(component: []const u8, id: []const u8) bool {
    return std.mem.eql(u8, component, id) or
        (std.mem.endsWith(u8, component, ".desktop") and std.mem.eql(u8, component[0 .. component.len - 8], id));
}
fn resolveFlatpak(a: std.mem.Allocator, io: std.Io, id: []const u8, candidates: *std.ArrayList(Candidate)) !void {
    var manager: Flatpak = .{ .allocator = a, .io = io };
    defer manager.deinit();
    const installed = try manager.list_installed_applications();
    defer fp.InstalledApplication.deinitSlice(a, installed);
    // Installed references remain usable even if their remote/catalog was removed.
    if (try appendInstalled(a, id, installed, candidates)) return;
    const catalogs = try manager.get_all_remote_appstreams(null);
    defer fp.AppstreamCatalog.deinitSlice(a, catalogs);
    for (catalogs) |catalog| for (catalog.apps) |app| {
        if (!matchesFlatpak(id, app.id) and !matchesFlatpak(app.id, id)) continue;
        const app_id = if (std.mem.endsWith(u8, app.id, ".desktop")) app.id[0 .. app.id.len - 8] else app.id;
        try candidates.append(a, .{
            .source = .flatpak,
            .id = try a.dupe(u8, app_id),
            .name = try a.dupe(u8, app.name),
            .summary = try a.dupe(u8, app.summary),
            .installed = false,
            .remote = try a.dupe(u8, catalog.remote_name),
            .scope = @tagName(catalog.scope),
        });
    };
}

fn appendInstalled(a: std.mem.Allocator, id: []const u8, installed: []const fp.InstalledApplication, candidates: *std.ArrayList(Candidate)) !bool {
    var matched_installed = false;
    for (installed) |app| {
        if (app.kind != .app or !matchesFlatpak(id, app.id)) continue;
        matched_installed = true;
        try candidates.append(a, .{
            .source = .flatpak,
            .id = try a.dupe(u8, app.id),
            .name = try a.dupe(u8, app.name),
            .summary = try a.dupe(u8, app.summary),
            .installed = true,
            .remote = try a.dupe(u8, app.origin),
            .scope = @tagName(app.scope),
            .ref = try std.fmt.allocPrint(a, "app/{s}/{s}/{s}", .{ app.id, app.arch, app.branch }),
        });
    }
    return matched_installed;
}

test "AppStream metadata preserves component identity and desktop launchable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseMetadata(arena.allocator(), "<component type=\"desktop-application\"><id>org.example.Editor</id><launchable type=\"desktop-id\">different-name.desktop</launchable></component>");
    try std.testing.expectEqualStrings("org.example.Editor", value.id);
    try std.testing.expectEqualStrings("different-name.desktop", value.desktops[0]);
    try std.testing.expect(!validId("../etc/passwd"));
    try std.testing.expect(!validId("app/id"));
    try std.testing.expect(validId("chromium.desktop"));
    try std.testing.expect(matchesFlatpak("org.example.App.desktop", "org.example.App"));
    try std.testing.expect(!matchesFlatpak("org.example.AppExtra", "org.example.App"));
}

test "AppStream Flatpak resolution retains separate installations and branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var applications: [3]fp.InstalledApplication = undefined;
    for (&applications) |*app| app.* = .{
        .id = @constCast("org.example.App"),
        .name = @constCast("App"),
        .arch = @constCast("x86_64"),
        .branch = @constCast("stable"),
        .summary = @constCast(""),
        .version = @constCast("1"),
        .latest_commit = @constCast(""),
        .origin = @constCast("flathub"),
        .kind = .app,
        .installed_size = 0,
        .scope = .system,
    };
    applications[1].scope = .user;
    applications[2].scope = .user;
    applications[2].branch = @constCast("beta");
    var candidates: std.ArrayList(Candidate) = .empty;
    try std.testing.expect(try appendInstalled(a, "org.example.App.desktop", &applications, &candidates));
    try std.testing.expectEqual(@as(usize, 3), candidates.items.len);
    try std.testing.expectEqualStrings("system", candidates.items[0].scope);
    try std.testing.expectEqualStrings("user", candidates.items[1].scope);
    try std.testing.expectEqualStrings("app/org.example.App/x86_64/beta", candidates.items[2].ref);
    var absent: std.ArrayList(Candidate) = .empty;
    try std.testing.expect(!try appendInstalled(a, "org.example.AppExtra", &applications, &absent));
    try std.testing.expectEqual(@as(usize, 0), absent.items.len);
}
