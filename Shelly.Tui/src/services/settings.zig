const keybindings = @import("keybindings.zig");
const std = @import("std");
const Settings = @import("../models/settings.zig").Settings;
const xdg = @import("../xdg_paths.zig").xdg_paths;

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Store {
        const root = try xdg.xdgConfigHome(allocator, env);
        defer allocator.free(root);
        return .{ .allocator = allocator, .path = try std.fs.path.join(allocator, &.{ root, "shelly", "tui-settings.json" }) };
    }

    pub fn deinit(self: Store) void {
        self.allocator.free(self.path);
    }

    fn read(self: Store, io: std.Io) !std.json.Parsed(std.json.Value) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return std.json.parseFromSlice(std.json.Value, self.allocator, "{}", .{ .allocate = .alloc_always }),
            else => return err,
        };
        defer self.allocator.free(bytes);
        return std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{ .allocate = .alloc_always });
    }

    pub fn load(self: Store, io: std.Io) !Settings {
        const document = try self.read(io);
        defer document.deinit();
        return decode(document.value);
    }

    /// Re-read before patching, preserve unrelated keys, and commit atomically.
    /// Invalid files are reported and left intact, never replaced by defaults.
    pub fn save(self: Store, io: std.Io, settings: Settings) !void {
        var document = try self.read(io);
        defer document.deinit();
        _ = try decode(document.value);
        const alloc = document.arena.allocator();
        // The CLI owns AurUrl.
        _ = document.value.object.swapRemove("AtollAurEnabled");
        try document.value.object.put(alloc, "AurEnabled", .{ .bool = settings.aur_enabled });
        try document.value.object.put(alloc, "FlatpakEnabled", .{ .bool = settings.flatpak_enabled });
        try document.value.object.put(alloc, "HeaderIcons", .{ .string = @tagName(settings.header_icons) });
        try document.value.object.put(alloc, "ShowFlatpakScreenshots", .{ .bool = settings.show_flatpak_screenshots });
        const overrides = try keybindings.encode(alloc, settings.keybindings);
        if (overrides.object.count() > 0) {
            try document.value.object.put(alloc, "Keybindings", overrides);
        } else {
            _ = document.value.object.swapRemove("Keybindings");
        }
        var staged = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{ .make_path = true, .replace = true });
        defer staged.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = staged.file.writer(io, &buffer);
        try writer.interface.print("{f}\n", .{std.json.fmt(document.value, .{ .whitespace = .indent_2 })});
        try writer.flush();
        try staged.file.sync(io);
        try staged.replace(io);
    }
};

fn decode(value: std.json.Value) !Settings {
    if (value != .object) return error.InvalidSettings;
    var result: Settings = .{};
    if (value.object.get("AurEnabled")) |enabled| {
        if (enabled != .bool) return error.InvalidSettings;
        result.aur_enabled = enabled.bool;
    }
    if (value.object.get("FlatpakEnabled")) |enabled| {
        if (enabled != .bool) return error.InvalidSettings;
        result.flatpak_enabled = enabled.bool;
    }
    if (value.object.get("ShowFlatpakScreenshots")) |show| {
        if (show != .bool) return error.InvalidSettings;
        result.show_flatpak_screenshots = show.bool;
    }
    if (value.object.get("HeaderIcons")) |icons| {
        if (icons != .string) return error.InvalidSettings;
        result.header_icons = if (std.mem.eql(u8, icons.string, "nerd_font")) .nerd_font else if (std.mem.eql(u8, icons.string, "ascii")) .ascii else if (std.mem.eql(u8, icons.string, "none") or std.mem.eql(u8, icons.string, "graphics") or std.mem.eql(u8, icons.string, "unicode")) .none else return error.InvalidSettings;
    }
    if (value.object.get("Keybindings")) |bindings| result.keybindings = try keybindings.decode(bindings);
    return result;
}

test "settings round trip preserves unknown keys and rejects invalid files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const store: Store = .{ .allocator = allocator, .path = try std.fs.path.join(allocator, &.{ directory, "tui-settings.json" }) };
    defer store.deinit();
    try std.testing.expect((try store.load(io)).eql(.{}));
    var file = try temporary.dir.createFile(io, "tui-settings.json", .{});
    try file.writeStreamingAll(io, "{\"Other\":{\"value\":42},\"AurEnabled\":true}");
    file.close(io);
    try store.save(io, .{ .flatpak_enabled = true, .show_flatpak_screenshots = false });
    try std.testing.expect((try store.load(io)).eql(.{ .flatpak_enabled = true, .show_flatpak_screenshots = false }));
    const document = try store.read(io);
    defer document.deinit();
    try std.testing.expectEqual(@as(i64, 42), document.value.object.get("Other").?.object.get("value").?.integer);
    for ([_]@import("../models/settings.zig").HeaderIcons{ .nerd_font, .ascii, .none }) |style| {
        try store.save(io, .{ .header_icons = style });
        try std.testing.expectEqual(style, (try store.load(io)).header_icons);
    }
    file = try temporary.dir.createFile(io, "tui-settings.json", .{ .truncate = true });
    try file.writeStreamingAll(io, "{\"AurEnabled\":\"invalid\"}");
    file.close(io);
    try std.testing.expectError(error.InvalidSettings, store.save(io, .{ .aur_enabled = true }));
    const kept = try temporary.dir.readFileAlloc(io, "tui-settings.json", allocator, .limited(4096));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("{\"AurEnabled\":\"invalid\"}", kept);
}

test "header icons default for old files and reject unsupported values" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"AurEnabled\":true}", "{\"HeaderIcons\":\"unicode\"}", "{\"HeaderIcons\":\"graphics\"}" }) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@import("../models/settings.zig").HeaderIcons.none, (try decode(parsed.value)).header_icons);
    }
    for ([_][]const u8{ "{\"HeaderIcons\":true}", "{\"HeaderIcons\":\"nerd-font\"}" }) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidSettings, decode(parsed.value));
    }
}

test "screenshot preference defaults on and requires a boolean" {
    for ([_][]const u8{ "{}", "{\"ShowFlatpakScreenshots\":true}" }) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect((try decode(parsed.value)).show_flatpak_screenshots);
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"ShowFlatpakScreenshots\":\"false\"}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidSettings, decode(parsed.value));
}

test "TUI settings do not override the CLI AUR source" {
    const allocator = std.testing.allocator;
    const missing = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer missing.deinit();
    try std.testing.expect(!(try decode(missing.value)).atoll_aur_enabled);
    const invalid = try std.json.parseFromSlice(std.json.Value, allocator, "{\"AtollAurEnabled\":\"true\"}", .{});
    defer invalid.deinit();
    try std.testing.expect(!(try decode(invalid.value)).atoll_aur_enabled);
}

test "keybinding overrides persist atomically without changing unrelated settings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const store: Store = .{ .allocator = allocator, .path = try std.fs.path.join(allocator, &.{ directory, "tui-settings.json" }) };
    defer store.deinit();
    var file = try temporary.dir.createFile(io, "tui-settings.json", .{});
    try file.writeStreamingAll(io, "{\"Other\":42,\"AurEnabled\":true}");
    file.close(io);
    var saved = try store.load(io);
    try std.testing.expect(saved.keybindings.eql(.{}));
    saved.keybindings = try saved.keybindings.withBinding(.help, try keybindings.parse("F2"));
    try store.save(io, saved);
    try std.testing.expect((try store.load(io)).eql(saved));
    var document = try store.read(io);
    try std.testing.expectEqual(@as(i64, 42), document.value.object.get("Other").?.integer);
    try std.testing.expectEqual(@as(usize, 1), document.value.object.get("Keybindings").?.object.count());
    document.deinit();
    const before = try temporary.dir.readFileAlloc(io, "tui-settings.json", allocator, .limited(4096));
    defer allocator.free(before);
    saved.keybindings.overrides[0] = try keybindings.parse("F2"); // Quit collides with Help.
    try std.testing.expectError(error.ConflictingBinding, store.save(io, saved));
    const after = try temporary.dir.readFileAlloc(io, "tui-settings.json", allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    saved.keybindings = .{};
    try store.save(io, saved);
    document = try store.read(io);
    defer document.deinit();
    try std.testing.expect(document.value.object.get("Keybindings") == null);
    try std.testing.expect((try store.load(io)).keybindings.eql(.{}));
}

test "invalid keybinding files are reported and never overwritten by save" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const store: Store = .{ .allocator = allocator, .path = try std.fs.path.join(allocator, &.{ directory, "tui-settings.json" }) };
    defer store.deinit();
    const json = "{\"Keybindings\":{\"confirm\":\"F2\"},\"Other\":42}";
    var file = try temporary.dir.createFile(io, "tui-settings.json", .{});
    try file.writeStreamingAll(io, json);
    file.close(io);
    try std.testing.expectError(error.FixedCommand, store.load(io));
    try std.testing.expectError(error.FixedCommand, store.save(io, .{}));
    const after = try temporary.dir.readFileAlloc(io, "tui-settings.json", allocator, .limited(4096));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(json, after);
}
