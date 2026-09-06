const std = @import("std");
const model = @import("model.zig");
const runtime = @import("../runtime/context.zig");
const xdg = @import("../runtime/xdg.zig");
const native_defaults = @import("defaults.zig");

pub const Manager = struct {
    context: *runtime.RuntimeContext,

    pub fn init(context: *runtime.RuntimeContext) Manager {
        return .{ .context = context };
    }

    pub fn path(self: Manager) ![]const u8 {
        return xdg.configPath(self.context);
    }

    pub fn read(self: Manager) !model.Config {
        var config = try model.Config.defaults(self.context.allocator);
        const config_path = try self.path();
        const contents = std.Io.Dir.cwd().readFileAlloc(
            self.context.io,
            config_path,
            self.context.allocator,
            .limited(4 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try self.save(&config);
                return config;
            },
            else => return err,
        };
        const parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.context.allocator,
            contents,
            .{},
        );
        if (parsed != .object) return error.InvalidConfig;
        try config.overlay(parsed.object);
        return config;
    }

    pub fn save(self: Manager, config: *const model.Config) !void {
        const config_path = try self.path();
        if (std.fs.path.dirname(config_path)) |directory|
            try std.Io.Dir.cwd().createDirPath(self.context.io, directory);

        var output = std.Io.Writer.Allocating.init(self.context.allocator);
        defer output.deinit();
        try std.json.Stringify.value(
            std.json.Value{ .object = config.values },
            .{ .whitespace = .indent_2, .escape_unicode = true },
            &output.writer,
        );
        var file = try std.Io.Dir.createFileAbsolute(self.context.io, config_path, .{});
        defer file.close(self.context.io);
        try file.writeStreamingAll(self.context.io, output.writer.buffered());
    }

    pub fn reset(self: Manager) !void {
        const config = try model.Config.defaults(self.context.allocator);
        try self.save(&config);
    }

    pub fn update(self: Manager, key: []const u8, value: []const u8) !bool {
        var config = try self.read();
        if (!try config.set(self.context.allocator, key, value)) return false;
        try self.save(&config);
        return true;
    }

    pub fn get(self: Manager, key: []const u8) !?[]const u8 {
        const config = try self.read();
        return config.getDisplay(self.context.allocator, key);
    }
};

test "creates, updates, and reloads the XDG config file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", "/home/tester");
    try environment.put("XDG_CONFIG_HOME", absolute_buffer[0..absolute_length]);
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };
    const manager = Manager.init(&context);
    const config = try manager.read();
    try std.testing.expectEqualStrings("10", (try config.getDisplay(arena.allocator(), "ParallelDownloadCount")).?);
    try std.testing.expectEqualStrings(
        "PreferIPv4",
        (try config.getDisplay(arena.allocator(), "DownloadAddressFamilyPolicy")).?,
    );
    try std.testing.expectEqualStrings(
        "False",
        (try config.getDisplay(arena.allocator(), "AutoConfirmCacheClean")).?,
    );

    const saved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "shelly/config.json",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings(
        std.mem.trimEnd(u8, native_defaults.json, "\n"),
        saved,
    );

    try std.testing.expect(try manager.update("ParallelDownloadCount", "22"));
    try std.testing.expectEqualStrings("22", (try manager.get("parallelDownloadCount")).?);
    try std.testing.expect(!try manager.update("ParallelDownloadCount", "many"));
    try std.testing.expect(try manager.update("DownloadAddressFamilyPolicy", "ipv6only"));
    try std.testing.expectEqualStrings(
        "IPv6Only",
        (try manager.get("downloadaddressfamilypolicy")).?,
    );
    try std.testing.expect(!try manager.update("DownloadAddressFamilyPolicy", "automatic"));
    try std.testing.expect(try manager.update("AutoConfirmCacheClean", "true"));
    try std.testing.expectEqualStrings(
        "True",
        (try manager.get("AutoConfirmCacheClean")).?,
    );
    try std.testing.expect(!try manager.update("AutoConfirmCacheClean", "yes"));
    try std.testing.expectEqualStrings("False", (try manager.get("DisableCacheClean")).?);
    try std.testing.expect(try manager.update("disablecacheclean", "TrUe"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableCacheClean")).?);
    try std.testing.expect(!try manager.update("DisableCacheClean", "yes"));
    try std.testing.expectEqualStrings("True", (try manager.get("DisableCacheClean")).?);
    try manager.reset();
    try std.testing.expectEqualStrings("False", (try manager.get("DisableCacheClean")).?);
}
