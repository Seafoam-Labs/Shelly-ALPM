const std = @import("std");
const builtin = @import("builtin");
const context_module = @import("context.zig");

pub const Error = error{
    UnsupportedPlatform,
    ElevationFailed,
};

pub fn isRoot() bool {
    return builtin.os.tag == .linux and std.os.linux.geteuid() == 0;
}

/// Relaunches the current executable through the configured privilege
/// elevator when the process is not already root. A non-null result is the
/// elevated child's exit code and must be returned by the caller immediately.
pub fn relaunchIfNeeded(
    context: *context_module.RuntimeContext,
    arguments: []const []const u8,
) !?u8 {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (isRoot()) return null;

    const executable = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable);
    const elevator = findElevator(context);
    const elevated_arguments = try buildArguments(context.allocator, elevator, executable, arguments);
    defer context.allocator.free(elevated_arguments);

    var child = try std.process.spawn(context.io, .{
        .argv = elevated_arguments,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(context.io);

    return @as(?u8, try exitCode(try child.wait(context.io)));
}

/// Runs the current executable as the user who invoked sudo/doas. This keeps
/// per-user package stores (notably Flatpak) attached to the calling user when
/// an aggregate command is already running as root. Returns null when the
/// process was not elevated by a supported caller-preserving tool.
pub fn runAsInvokingUser(
    context: *context_module.RuntimeContext,
    arguments: []const []const u8,
) !?u8 {
    const user = invokingUser(context) orelse return null;
    const home = try invokingUserHome(context, user);
    defer context.allocator.free(home);
    const executable = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable);
    const home_environment = try std.fmt.allocPrint(context.allocator, "HOME={s}", .{home});
    defer context.allocator.free(home_environment);
    const xdg_environment = try std.fmt.allocPrint(
        context.allocator,
        "XDG_DATA_HOME={s}/.local/share",
        .{home},
    );
    defer context.allocator.free(xdg_environment);
    const child_arguments = try buildInvokingUserArguments(
        context.allocator,
        findElevator(context),
        user,
        executable,
        home_environment,
        xdg_environment,
        arguments,
    );
    defer context.allocator.free(child_arguments);

    var child = try std.process.spawn(context.io, .{
        .argv = child_arguments,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(context.io);
    return @as(?u8, try exitCode(try child.wait(context.io)));
}

fn findElevator(context: *const context_module.RuntimeContext) []const u8 {
    if (context.environment) |environment| {
        if (environment.get("SHELLY_ELEVATOR")) |configured| {
            const trimmed = std.mem.trim(u8, configured, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        if (environment.get("PATH")) |path| {
            if (isOnPath(context, path, "doas")) return "doas";
            if (isOnPath(context, path, "sudo")) return "sudo";
        }
    }
    return "sudo";
}

fn isOnPath(
    context: *const context_module.RuntimeContext,
    path_environment: []const u8,
    executable: []const u8,
) bool {
    var paths = std.mem.splitScalar(u8, path_environment, ':');
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        const candidate = std.fs.path.join(context.allocator, &.{ path, executable }) catch continue;
        defer context.allocator.free(candidate);
        std.Io.Dir.accessAbsolute(context.io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

fn buildArguments(
    allocator: std.mem.Allocator,
    elevator: []const u8,
    executable: []const u8,
    arguments: []const []const u8,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, arguments.len + 2);
    result[0] = elevator;
    result[1] = executable;
    @memcpy(result[2..], arguments);
    return result;
}

fn buildInvokingUserArguments(
    allocator: std.mem.Allocator,
    elevator: []const u8,
    user: []const u8,
    executable: []const u8,
    home_environment: []const u8,
    xdg_environment: []const u8,
    arguments: []const []const u8,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, arguments.len + 7);
    result[0] = elevator;
    result[1] = "-u";
    result[2] = user;
    result[3] = "env";
    result[4] = home_environment;
    result[5] = xdg_environment;
    result[6] = executable;
    @memcpy(result[7..], arguments);
    return result;
}

fn invokingUser(context: *const context_module.RuntimeContext) ?[]const u8 {
    const environment = context.environment orelse return null;
    const user = environment.get("SUDO_USER") orelse environment.get("DOAS_USER") orelse return null;
    if (user.len == 0 or std.mem.eql(u8, user, "root")) return null;
    return user;
}

fn invokingUserHome(
    context: *const context_module.RuntimeContext,
    user: []const u8,
) ![]u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        "/etc/passwd",
        context.allocator,
        .limited(1024 * 1024),
    ) catch return Error.ElevationFailed;
    defer context.allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const candidate = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const home = fields.next() orelse continue;
        if (std.mem.eql(u8, candidate, user) and home.len > 0)
            return context.allocator.dupe(u8, home);
    }
    return Error.ElevationFailed;
}

fn exitCode(term: std.process.Child.Term) Error!u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @intFromEnum(signal)),
        .stopped, .unknown => error.ElevationFailed,
    };
}

test "elevated arguments preserve the canonical invocation" {
    const arguments = [_][]const u8{ "sync", "standard", "--force" };
    const elevated = try buildArguments(std.testing.allocator, "doas", "/usr/bin/shelly", &arguments);
    defer std.testing.allocator.free(elevated);

    const expected = [_][]const u8{ "doas", "/usr/bin/shelly", "sync", "standard", "--force" };
    try std.testing.expectEqual(expected.len, elevated.len);
    for (expected, elevated) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
}

test "elevation child status maps to shell exit codes" {
    try std.testing.expectEqual(@as(u8, 7), try exitCode(.{ .exited = 7 }));
    try std.testing.expectError(error.ElevationFailed, exitCode(.{ .unknown = 1 }));
}

test "calling-user arguments preserve Flatpak user storage" {
    const arguments = [_][]const u8{ "upgrade", "flatpak", "--no-confirm" };
    const actual = try buildInvokingUserArguments(
        std.testing.allocator,
        "sudo",
        "tester",
        "/usr/bin/shelly",
        "HOME=/home/tester",
        "XDG_DATA_HOME=/home/tester/.local/share",
        &arguments,
    );
    defer std.testing.allocator.free(actual);

    const expected = [_][]const u8{
        "sudo",
        "-u",
        "tester",
        "env",
        "HOME=/home/tester",
        "XDG_DATA_HOME=/home/tester/.local/share",
        "/usr/bin/shelly",
        "upgrade",
        "flatpak",
        "--no-confirm",
    };
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, value| try std.testing.expectEqualStrings(wanted, value);
}
