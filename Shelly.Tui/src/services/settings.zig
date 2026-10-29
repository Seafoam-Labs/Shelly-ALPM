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
        try document.value.object.put(alloc, "AurEnabled", .{ .bool = settings.aur_enabled });
        try document.value.object.put(alloc, "FlatpakEnabled", .{ .bool = settings.flatpak_enabled });
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
    try store.save(io, .{ .flatpak_enabled = true });
    try std.testing.expect((try store.load(io)).eql(.{ .flatpak_enabled = true }));
    const document = try store.read(io);
    defer document.deinit();
    try std.testing.expectEqual(@as(i64, 42), document.value.object.get("Other").?.object.get("value").?.integer);
    file = try temporary.dir.createFile(io, "tui-settings.json", .{ .truncate = true });
    try file.writeStreamingAll(io, "{\"AurEnabled\":\"invalid\"}");
    file.close(io);
    try std.testing.expectError(error.InvalidSettings, store.save(io, .{ .aur_enabled = true }));
    const kept = try temporary.dir.readFileAlloc(io, "tui-settings.json", allocator, .limited(4096));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("{\"AurEnabled\":\"invalid\"}", kept);
}
