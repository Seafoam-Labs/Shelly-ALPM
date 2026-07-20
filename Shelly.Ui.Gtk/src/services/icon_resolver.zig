const std = @import("std");
const xdg_paths = @import("xdg_paths.zig").xdg_paths;

pub const IconResolver = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged([:0]const u8) = .empty,
    loaded: bool = false,

    const sizes = [_][]const u8{ "64x64", "128x128", "48x48" };

    pub fn init(backing: std.mem.Allocator) IconResolver {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *IconResolver) void {
        self.arena.deinit();
    }

    pub fn load(self: *IconResolver, io: std.Io, env: *const std.process.Environ.Map) !void {
        const alloc = self.arena.allocator();
        const data_home = try xdg_paths.xdgDataHome(alloc, env);
        const base = try std.fs.path.join(alloc, &.{ data_home, "shelly-icons" });
        try self.loadFrom(io, base);
    }

    pub fn loadFrom(self: *IconResolver, io: std.Io, base_path: []const u8) !void {
        const alloc = self.arena.allocator();

        const manifest_path = try std.fs.path.join(alloc, &.{ base_path, "manifest.json" });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            manifest_path,
            alloc,
            std.Io.Limit.limited(32 * 1024 * 1024),
        );

        const manifest = try std.json.parseFromSliceLeaky(
            std.json.ArrayHashMap([]const []const u8),
            alloc,
            bytes,
            .{ .duplicate_field_behavior = .use_last },
        );

        var it = manifest.map.iterator();
        while (it.next()) |kv| {
            const icons = kv.value_ptr.*;
            if (icons.len == 0) continue;

            if (pickIcon(io, alloc, base_path, icons)) |path| {
                const key = try alloc.dupe(u8, kv.key_ptr.*);
                try self.map.put(alloc, key, path);
            }
        }

        self.loaded = true;
    }

    pub fn resolve(self: *const IconResolver, package_name: []const u8) ?[:0]const u8 {
        return self.map.get(package_name);
    }

    fn pickIcon(io: std.Io, alloc: std.mem.Allocator, base_path: []const u8, icons: []const []const u8) ?[:0]const u8 {
        for (sizes) |size| {
            for (icons) |icon| {
                if (std.mem.indexOf(u8, icon, size) == null) continue;
                if (existingPath(io, alloc, base_path, icon)) |p| return p;
            }
        }
        for (icons) |icon| {
            if (existingPath(io, alloc, base_path, icon)) |p| return p;
        }
        return null;
    }

    fn existingPath(io: std.Io, alloc: std.mem.Allocator, base_path: []const u8, relative: []const u8) ?[:0]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ base_path, relative }) catch return null;
        std.Io.Dir.cwd().access(io, p, .{}) catch return null;
        return alloc.dupeZ(u8, p) catch null;
    }
};

// test "resolves an icon from the real shelly-icons directory" {
//     var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
//     defer threaded.deinit();

//     var r = IconResolver.init(std.testing.allocator);
//     defer r.deinit();

//     try r.load(threaded.io(), std.testing.environ);
//     try std.testing.expect(r.loaded);

//     const p = r.resolve("firefox");
//     std.debug.print("firefox -> {?s}\n", .{p});
// }
