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
    const safe_executable: []const u8 = std.mem.trimEnd(u8, executable, " (deleted)");
    defer context.allocator.free(executable);
    const elevator = findElevator(context);
    const elevated_arguments = try buildArguments(context.allocator, elevator, safe_executable, arguments);
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

/// Runs the current executable as the user who invoked sudo/doas/pkexec/run0. This
/// keeps per-user package stores (notably Flatpak) attached to the calling
/// user when an aggregate command is already running as root. The child also
/// receives the calling user's runtime directory and session bus address so
/// system-scope Flatpak operations can authenticate through the Flatpak
/// helper. Returns null when the process was not elevated by a supported
/// caller-preserving tool.
pub fn runAsInvokingUser(
    context: *context_module.RuntimeContext,
    arguments: []const []const u8,
) !?u8 {
    const identity = (try invokingUser(context)) orelse return null;
    defer identity.deinit(context.allocator);
    const home = try invokingUserHome(context, identity.username);
    defer context.allocator.free(home);
    const executable = try std.process.executablePathAlloc(context.io, context.allocator);
    const safe_executable: []const u8 = std.mem.trimEnd(u8, executable, " (deleted)");
    defer context.allocator.free(executable);
    const home_environment = try std.fmt.allocPrint(context.allocator, "HOME={s}", .{home});
    defer context.allocator.free(home_environment);
    const config_environment = try std.fmt.allocPrint(
        context.allocator,
        "XDG_CONFIG_HOME={s}/.config",
        .{home},
    );
    defer context.allocator.free(config_environment);
    const data_environment = try std.fmt.allocPrint(
        context.allocator,
        "XDG_DATA_HOME={s}/.local/share",
        .{home},
    );
    defer context.allocator.free(data_environment);
    const cache_environment = try std.fmt.allocPrint(
        context.allocator,
        "XDG_CACHE_HOME={s}/.cache",
        .{home},
    );
    defer context.allocator.free(cache_environment);
    const bin_environment = try std.fmt.allocPrint(
        context.allocator,
        "XDG_BIN_HOME={s}/.local/bin",
        .{home},
    );
    defer context.allocator.free(bin_environment);
    const runtime_environment = try std.fmt.allocPrint(
        context.allocator,
        "XDG_RUNTIME_DIR=/run/user/{s}",
        .{identity.uid},
    );
    defer context.allocator.free(runtime_environment);
    const bus_environment = try std.fmt.allocPrint(
        context.allocator,
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{s}/bus",
        .{identity.uid},
    );
    defer context.allocator.free(bus_environment);
    const child_arguments = try buildInvokingUserArguments(
        context.allocator,
        findElevator(context),
        identity.username,
        safe_executable,
        home_environment,
        config_environment,
        data_environment,
        cache_environment,
        bin_environment,
        runtime_environment,
        bus_environment,
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
            if (isOnPath(context, path, "run0")) return "run0";
        }
    }
    return "sudo";
}

fn isRun0(elevator: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(elevator), "run0");
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
    config_environment: []const u8,
    data_environment: []const u8,
    cache_environment: []const u8,
    bin_environment: []const u8,
    runtime_environment: []const u8,
    bus_environment: []const u8,
    arguments: []const []const u8,
) ![]const []const u8 {
    if (isRun0(elevator)) {
        const result = try allocator.alloc([]const u8, arguments.len + 18);
        result[0] = elevator;
        result[1] = "--user";
        result[2] = user;
        result[3] = "--setenv";
        result[4] = home_environment;
        result[5] = "--setenv";
        result[6] = config_environment;
        result[7] = "--setenv";
        result[8] = data_environment;
        result[9] = "--setenv";
        result[10] = cache_environment;
        result[11] = "--setenv";
        result[12] = bin_environment;
        result[13] = "--setenv";
        result[14] = runtime_environment;
        result[15] = "--setenv";
        result[16] = bus_environment;
        result[17] = executable;
        @memcpy(result[18..], arguments);
        return result;
    }

    const result = try allocator.alloc([]const u8, arguments.len + 13);
    result[0] = elevator;
    result[1] = "-u";
    result[2] = user;
    result[3] = "env";
    result[4] = "-i";
    result[5] = home_environment;
    result[6] = config_environment;
    result[7] = data_environment;
    result[8] = cache_environment;
    result[9] = bin_environment;
    result[10] = runtime_environment;
    result[11] = bus_environment;
    result[12] = executable;
    @memcpy(result[13..], arguments);
    return result;
}

const InvokingIdentity = struct {
    username: []const u8,
    uid: []const u8,

    fn deinit(self: InvokingIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.uid);
    }
};

/// Resolves the username and uid of the user who invoked the current elevated
/// process, recognizing sudo, doas, pkexec, and run0. Returns null when the process
/// was not elevated by one of these tools or when the invoking user was root.
/// Both returned strings are owned by the caller.
fn invokingUser(context: *const context_module.RuntimeContext) !?InvokingIdentity {
    const environment = context.environment orelse return null;
    if (environment.get("SUDO_USER") == null and
        environment.get("DOAS_USER") == null and
        environment.get("PKEXEC_UID") == null) return null;
    const passwd = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        "/etc/passwd",
        context.allocator,
        .limited(1024 * 1024),
    ) catch return null;
    defer context.allocator.free(passwd);
    return invokingIdentity(context.allocator, environment, passwd);
}

fn invokingIdentity(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    passwd: []const u8,
) !?InvokingIdentity {
    if (environment.get("SUDO_USER")) |user| {
        if (validInvokingUser(user)) return try identityForUsername(allocator, passwd, user);
    }
    if (environment.get("DOAS_USER")) |user| {
        if (validInvokingUser(user)) return try identityForUsername(allocator, passwd, user);
    }
    const uid = environment.get("PKEXEC_UID") orelse return null;
    if (uid.len == 0) return null;
    const username = try usernameForUidInPasswd(allocator, passwd, uid) orelse return null;
    errdefer allocator.free(username);
    return InvokingIdentity{
        .username = username,
        .uid = try allocator.dupe(u8, uid),
    };
}

fn identityForUsername(
    allocator: std.mem.Allocator,
    passwd: []const u8,
    username: []const u8,
) !?InvokingIdentity {
    const uid = try uidForUsernameInPasswd(allocator, passwd, username) orelse return null;
    errdefer allocator.free(uid);
    return InvokingIdentity{
        .username = try allocator.dupe(u8, username),
        .uid = uid,
    };
}

fn validInvokingUser(user: []const u8) bool {
    return user.len > 0 and !std.mem.eql(u8, user, "root");
}

fn usernameForUidInPasswd(
    allocator: std.mem.Allocator,
    passwd: []const u8,
    wanted_uid: []const u8,
) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const username = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid = fields.next() orelse continue;
        if (std.mem.eql(u8, uid, wanted_uid) and validInvokingUser(username))
            return try allocator.dupe(u8, username);
    }
    return null;
}

fn uidForUsernameInPasswd(
    allocator: std.mem.Allocator,
    passwd: []const u8,
    wanted_username: []const u8,
) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const username = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const uid = fields.next() orelse continue;
        if (std.mem.eql(u8, username, wanted_username) and uid.len > 0)
            return try allocator.dupe(u8, uid);
    }
    return null;
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

test "run0 root arguments preserve the canonical invocation" {
    const arguments = [_][]const u8{ "sync", "standard", "--force" };
    const elevated = try buildArguments(std.testing.allocator, "run0", "/usr/bin/shelly", &arguments);
    defer std.testing.allocator.free(elevated);

    const expected = [_][]const u8{ "run0", "/usr/bin/shelly", "sync", "standard", "--force" };
    try std.testing.expectEqual(expected.len, elevated.len);
    for (expected, elevated) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
}

test "automatic elevator precedence honors override and PATH discovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ "doas", "sudo", "run0" }) |name| {
        var fixture = try temporary.dir.createFile(std.testing.io, name, .{
            .permissions = .executable_file,
        });
        fixture.close(std.testing.io);
    }

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("PATH", path_buffer[0..path_length]);
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: context_module.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };

    try std.testing.expectEqualStrings("doas", findElevator(&context));
    try temporary.dir.deleteFile(std.testing.io, "doas");
    try std.testing.expectEqualStrings("sudo", findElevator(&context));
    try temporary.dir.deleteFile(std.testing.io, "sudo");
    try std.testing.expectEqualStrings("run0", findElevator(&context));
    try environment.put("SHELLY_ELEVATOR", "  pkexec \n");
    try std.testing.expectEqualStrings("pkexec", findElevator(&context));
}

test "elevation child status maps to shell exit codes" {
    try std.testing.expectEqual(@as(u8, 7), try exitCode(.{ .exited = 7 }));
    try std.testing.expectError(error.ElevationFailed, exitCode(.{ .unknown = 1 }));
}

test "calling-user arguments use a clean invoking-user environment" {
    const arguments = [_][]const u8{ "upgrade", "flatpak", "--no-confirm" };
    const actual = try buildInvokingUserArguments(
        std.testing.allocator,
        "sudo",
        "tester",
        "/usr/bin/shelly",
        "HOME=/home/tester",
        "XDG_CONFIG_HOME=/home/tester/.config",
        "XDG_DATA_HOME=/home/tester/.local/share",
        "XDG_CACHE_HOME=/home/tester/.cache",
        "XDG_BIN_HOME=/home/tester/.local/bin",
        "XDG_RUNTIME_DIR=/run/user/1000",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
        &arguments,
    );
    defer std.testing.allocator.free(actual);

    const expected = [_][]const u8{
        "sudo",
        "-u",
        "tester",
        "env",
        "-i",
        "HOME=/home/tester",
        "XDG_CONFIG_HOME=/home/tester/.config",
        "XDG_DATA_HOME=/home/tester/.local/share",
        "XDG_CACHE_HOME=/home/tester/.cache",
        "XDG_BIN_HOME=/home/tester/.local/bin",
        "XDG_RUNTIME_DIR=/run/user/1000",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
        "/usr/bin/shelly",
        "upgrade",
        "flatpak",
        "--no-confirm",
    };
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, value| try std.testing.expectEqualStrings(wanted, value);
}

test "run0 invoking-user arguments use native options" {
    const arguments = [_][]const u8{ "upgrade", "flatpak", "--no-confirm" };
    const actual = try buildInvokingUserArguments(
        std.testing.allocator,
        "/usr/bin/run0",
        "tester",
        "/usr/bin/shelly",
        "HOME=/home/tester",
        "XDG_CONFIG_HOME=/home/tester/.config",
        "XDG_DATA_HOME=/home/tester/.local/share",
        "XDG_CACHE_HOME=/home/tester/.cache",
        "XDG_BIN_HOME=/home/tester/.local/bin",
        "XDG_RUNTIME_DIR=/run/user/1000",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
        &arguments,
    );
    defer std.testing.allocator.free(actual);

    const expected = [_][]const u8{
        "/usr/bin/run0",
        "--user",
        "tester",
        "--setenv",
        "HOME=/home/tester",
        "--setenv",
        "XDG_CONFIG_HOME=/home/tester/.config",
        "--setenv",
        "XDG_DATA_HOME=/home/tester/.local/share",
        "--setenv",
        "XDG_CACHE_HOME=/home/tester/.cache",
        "--setenv",
        "XDG_BIN_HOME=/home/tester/.local/bin",
        "--setenv",
        "XDG_RUNTIME_DIR=/run/user/1000",
        "--setenv",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
        "/usr/bin/shelly",
        "upgrade",
        "flatpak",
        "--no-confirm",
    };
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, value| try std.testing.expectEqualStrings(wanted, value);
}

const sample_passwd =
    "root:x:0:0:root:/root:/usr/bin/zsh\n" ++
    "tester:x:1000:1000::/home/tester:/usr/bin/zsh\n" ++
    "other:x:2000:2000::/home/other:/usr/bin/zsh\n";

test "pkexec elevation resolves the invoking identity from passwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("PKEXEC_UID", "1000");

    const identity = (try invokingIdentity(std.testing.allocator, &environment, sample_passwd)).?;
    defer identity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tester", identity.username);
    try std.testing.expectEqualStrings("1000", identity.uid);
}

test "run0 elevation resolves its SUDO_USER invoking identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("SUDO_USER", "tester");

    const identity = (try invokingIdentity(std.testing.allocator, &environment, sample_passwd)).?;
    defer identity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tester", identity.username);
    try std.testing.expectEqualStrings("1000", identity.uid);
}

test "sudo elevation takes precedence over pkexec and resolves its uid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("SUDO_USER", "tester");
    try environment.put("PKEXEC_UID", "2000");

    const identity = (try invokingIdentity(std.testing.allocator, &environment, sample_passwd)).?;
    defer identity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tester", identity.username);
    try std.testing.expectEqualStrings("1000", identity.uid);
}

test "root callers are not treated as an invoking user" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("SUDO_USER", "root");
    try environment.put("PKEXEC_UID", "0");

    try std.testing.expect(try invokingIdentity(
        std.testing.allocator,
        &environment,
        sample_passwd,
    ) == null);
}

test "invoking identity is null without elevation markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", "/home/tester");

    try std.testing.expect(try invokingIdentity(
        std.testing.allocator,
        &environment,
        sample_passwd,
    ) == null);
}
