const std = @import("std");
const protocol = @import("Shelly_Flatpak_Protocol");
const options = @import("flatpak_backend_options");
const errors = @import("errors.zig");

pub const production_path: []const u8 = options.backend_path;

pub const BackendInfo = struct {
    abi_version: u32,
    path: []const u8,
};

pub const BackendStatus = union(enum) {
    available: BackendInfo,
    unavailable,
    incompatible: u32,
};

pub const Loaded = struct {
    library: std.DynLib,
    api: protocol.BackendApiV1,
    path: []const u8,
};

var load_mutex: std.atomic.Mutex = .unlocked;
var process_loaded: ?Loaded = null;
var incompatible_version: ?u32 = null;

pub fn acquire() errors.Error!*const Loaded {
    lock();
    defer load_mutex.unlock();
    if (process_loaded) |*loaded| return loaded;
    if (incompatible_version != null)
        return errors.Error.FlatpakBackendIncompatible;

    const loaded = openAndValidate(production_path) catch |err| switch (err) {
        errors.Error.FlatpakBackendIncompatible => {
            incompatible_version = protocol.abi_version;
            return err;
        },
        else => return err,
    };
    process_loaded = loaded;
    return &(process_loaded.?);
}

pub fn backendStatus() BackendStatus {
    const loaded = acquire() catch |err| return switch (err) {
        errors.Error.FlatpakBackendIncompatible => .{
            .incompatible = incompatible_version orelse 0,
        },
        else => .unavailable,
    };
    return .{ .available = .{
        .abi_version = loaded.api.abi_version,
        .path = loaded.path,
    } };
}

fn probePath(path: []const u8) BackendStatus {
    var loaded = openAndValidate(path) catch |err| return switch (err) {
        errors.Error.FlatpakBackendIncompatible => .{ .incompatible = protocol.abi_version },
        else => .unavailable,
    };
    defer loaded.library.close();
    return .{ .available = .{
        .abi_version = loaded.api.abi_version,
        .path = path,
    } };
}

fn openAndValidate(path: []const u8) errors.Error!Loaded {
    if (!std.fs.path.isAbsolute(path))
        return errors.Error.FlatpakBackendUnavailable;
    var library = std.DynLib.open(path) catch
        return errors.Error.FlatpakBackendUnavailable;
    errdefer library.close();
    const get_api = library.lookup(
        protocol.GetApiFn,
        protocol.get_api_symbol,
    ) orelse return errors.Error.FlatpakBackendIncompatible;
    const host: protocol.HostApiV1 = .{
        .struct_size = @sizeOf(protocol.HostApiV1),
        .abi_version = protocol.abi_version,
        .user_data = null,
        .emit_event = discardEvent,
    };
    var api = std.mem.zeroes(protocol.BackendApiV1);
    const status = get_api(protocol.abi_version, &host, &api);
    if (status == .incompatible)
        return errors.Error.FlatpakBackendIncompatible;
    errors.fromStatus(status) catch
        return errors.Error.FlatpakBackendIncompatible;
    if (!protocol.backendApiValid(&api))
        return errors.Error.FlatpakBackendIncompatible;
    return .{
        .library = library,
        .api = api,
        .path = path,
    };
}

fn discardEvent(
    _: ?*anyopaque,
    _: protocol.EventBuffer,
) callconv(.c) void {}

fn lock() void {
    var spins: usize = 0;
    while (!load_mutex.tryLock()) {
        if (spins < 64) {
            std.atomic.spinLoopHint();
            spins += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }
}

test "production backend discovery path is absolute" {
    try std.testing.expect(std.fs.path.isAbsolute(production_path));
}

test "missing backend path reports unavailable without loading cwd" {
    const status = probePath(
        "/definitely/not/a/shelly/libshelly-flatpak-backend.so.1",
    );
    try std.testing.expect(status == .unavailable);
}

test "relative backend paths are rejected" {
    const status = probePath("./libshelly-flatpak-backend.so.1");
    try std.testing.expect(status == .unavailable);
}
