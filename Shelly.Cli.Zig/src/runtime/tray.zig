const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("context.zig");
const elevation = @import("elevation.zig");

const Target = struct {
    bus: []const u8,
    uid: ?std.posix.uid_t = null,
    gid: ?std.posix.gid_t = null,

    fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.bus);
    }
};

/// Reuse the GUI's Refresh signal. Desktop integration is optional: a missing
/// sender, session bus, or tray must never change the package command's result.
pub fn refresh(context: *runtime.RuntimeContext) void {
    if (builtin.os.tag != .linux) return;
    send(context) catch {};
}

fn send(context: *runtime.RuntimeContext) !void {
    const target = (try resolveTarget(context, std.os.linux.geteuid())) orelse return;
    defer target.deinit(context.allocator);
    const bus_argument = try std.fmt.allocPrint(context.allocator, "--bus={s}", .{target.bus});
    defer context.allocator.free(bus_argument);

    // Use fixed executables and an empty environment when dropping privileges.
    // An explicit bus prevents D-Bus autolaunch on servers without a desktop.
    var environment = std.process.Environ.Map.init(context.allocator);
    defer environment.deinit();
    var child = try std.process.spawn(context.io, .{
        .argv = &.{
            "/usr/bin/timeout",             "2s",            "/usr/bin/dbus-send",
            bus_argument,                   "--type=signal", "/org/shellyorg/Notifications",
            "com.shellyorg.shelly.Refresh",
        },
        .environ_map = &environment,
        .uid = target.uid,
        .gid = target.gid,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(context.io);
    _ = try child.wait(context.io);
}

fn resolveTarget(context: *runtime.RuntimeContext, effective_uid: std.posix.uid_t) !?Target {
    if (effective_uid == 0) {
        const identity = (try elevation.invokingUser(context)) orelse return null;
        defer identity.deinit(context.allocator);
        return .{
            .bus = try std.fmt.allocPrint(context.allocator, "unix:path=/run/user/{s}/bus", .{identity.uid}),
            .uid = try std.fmt.parseUnsigned(std.posix.uid_t, identity.uid, 10),
            .gid = try std.fmt.parseUnsigned(std.posix.gid_t, identity.gid, 10),
        };
    }

    if (context.environment) |environment| {
        if (environment.get("DBUS_SESSION_BUS_ADDRESS")) |address| {
            if (address.len > 0) return .{ .bus = try context.allocator.dupe(u8, address) };
        }
        if (environment.get("XDG_RUNTIME_DIR")) |directory| {
            if (std.fs.path.isAbsolute(directory)) return .{
                .bus = try std.fmt.allocPrint(context.allocator, "unix:path={s}/bus", .{directory}),
            };
        }
    }
    return .{ .bus = try std.fmt.allocPrint(context.allocator, "unix:path=/run/user/{d}/bus", .{effective_uid}) };
}

test "tray refresh preserves the current user's session bus and falls back without autolaunch" {
    var tc: @import("../commands/test_support.zig").TestContext = .{};
    tc.init();
    defer tc.deinit();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    tc.context.environment = &environment;

    try environment.put("DBUS_SESSION_BUS_ADDRESS", "unix:abstract=/tmp/private-session");
    try environment.put("XDG_RUNTIME_DIR", "/tmp/runtime");
    const explicit = (try resolveTarget(&tc.context, 1000)).?;
    try std.testing.expectEqualStrings("unix:abstract=/tmp/private-session", explicit.bus);
    try std.testing.expect(explicit.uid == null and explicit.gid == null);

    try environment.put("DBUS_SESSION_BUS_ADDRESS", "");
    const xdg = (try resolveTarget(&tc.context, 1000)).?;
    try std.testing.expectEqualStrings("unix:path=/tmp/runtime/bus", xdg.bus);

    try environment.put("XDG_RUNTIME_DIR", "relative/path");
    const fallback = (try resolveTarget(&tc.context, 1000)).?;
    try std.testing.expectEqualStrings("unix:path=/run/user/1000/bus", fallback.bus);
}

test "tray refresh targets the NSS invoking user after elevation and skips direct root" {
    var tc: @import("../commands/test_support.zig").TestContext = .{};
    tc.init();
    defer tc.deinit();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    tc.context.environment = &environment;
    try environment.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/0/bus");
    try std.testing.expect(try resolveTarget(&tc.context, 0) == null);

    const account = (try @import("Zigalpm").user_account.byName(tc.context.allocator, "nobody")) orelse
        return error.SkipZigTest;
    const uid = try std.fmt.allocPrint(tc.context.allocator, "{d}", .{account.uid});
    const bus = try std.fmt.allocPrint(tc.context.allocator, "unix:path=/run/user/{d}/bus", .{account.uid});
    for ([_][]const u8{ "SUDO_USER", "DOAS_USER", "PKEXEC_UID" }) |marker| {
        try environment.put(marker, if (std.mem.eql(u8, marker, "PKEXEC_UID")) uid else account.username);
        const target = (try resolveTarget(&tc.context, 0)).?;
        try std.testing.expectEqualStrings(bus, target.bus);
        try std.testing.expectEqual(account.uid, target.uid.?);
        try std.testing.expectEqual(account.gid, target.gid.?);
        try environment.put(marker, "");
    }
}
