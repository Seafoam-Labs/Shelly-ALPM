const std = @import("std");
const config_manager = @import("manager.zig");
const PackageManager = @import("PackageManager");
const model = @import("model.zig");
const runtime = @import("../runtime/context.zig");
pub fn fromConfig(config: *const model.Config) !PackageManager.Manager.Backend {
    const value = config.values.get("NativePackageBackend") orelse return PackageManager.Manager.default_backend;
    if (value != .string) return error.InvalidBackend;
    const backend = try PackageManager.Manager.Backend.parse(value.string);
    try backend.validate();
    return backend;
}
pub fn apply(context: *runtime.RuntimeContext) !void {
    const config = try config_manager.Manager.init(context).read();
    try PackageManager.Manager.setDefaultBackend(try fromConfig(&config));
}
test "native backend setting validates saved values and compiled availability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var config = try model.Config.defaults(arena.allocator());
    try std.testing.expectEqual(PackageManager.Manager.default_backend, try fromConfig(&config));
    try std.testing.expect(try config.set(arena.allocator(), "NativePackageBackend", "rlpm"));
    try std.testing.expectEqual(PackageManager.Manager.Backend.rlpm, try fromConfig(&config));
    try config.values.put(arena.allocator(), "NativePackageBackend", .{ .string = "unknown" });
    try std.testing.expectError(error.InvalidBackend, fromConfig(&config));
    try config.values.put(arena.allocator(), "NativePackageBackend", .{ .string = "libalpm" });
    if (PackageManager.Manager.libalpm_enabled) try std.testing.expectEqual(PackageManager.Manager.Backend.libalpm, try fromConfig(&config)) else try std.testing.expectError(error.BackendUnavailable, fromConfig(&config));
}
