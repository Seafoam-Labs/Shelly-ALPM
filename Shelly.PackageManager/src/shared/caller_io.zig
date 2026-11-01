//! User-owned filesystem operations. Only the child changes credentials;
//! runuser initializes the account's primary and supplementary groups.
const std = @import("std");
const accounts = @import("user_account.zig");

pub const Command = struct {
    argv: [][]u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        self.* = undefined;
    }

    pub fn asConst(self: *const Command) []const []const u8 {
        return self.argv;
    }
};

fn appendOwned(allocator: std.mem.Allocator, args: *std.ArrayList([]u8), value: []u8) !void {
    errdefer allocator.free(value);
    try args.append(allocator, value);
}

pub fn command(allocator: std.mem.Allocator, environ: std.process.Environ, argv: []const []const u8) !Command {
    const account = try accounts.caller(allocator, environ);
    defer account.deinit(allocator);
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    if (std.c.geteuid() == 0 and account.uid != 0) {
        for ([_][]const u8{ "/usr/bin/runuser", "-u", account.username, "--", "/usr/bin/env", "-u", "SUDO_USER", "-u", "SUDO_UID", "-u", "SUDO_GID", "-u", "DOAS_USER", "-u", "PKEXEC_UID" }) |arg|
            try appendOwned(allocator, &args, try allocator.dupe(u8, arg));
        try appendOwned(allocator, &args, try std.fmt.allocPrint(allocator, "HOME={s}", .{account.home}));
        for ([_][2][]const u8{
            .{ "XDG_CACHE_HOME", ".cache" },      .{ "XDG_CONFIG_HOME", ".config" },
            .{ "XDG_DATA_HOME", ".local/share" }, .{ "XDG_STATE_HOME", ".local/state" },
            .{ "XDG_BIN_HOME", ".local/bin" },
        }) |entry| {
            const configured = environ.getPosix(entry[0]);
            const value = if (configured != null and std.fs.path.isAbsolute(configured.?))
                try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry[0], configured.? })
            else
                try std.fmt.allocPrint(allocator, "{s}={s}/{s}", .{ entry[0], account.home, entry[1] });
            try appendOwned(allocator, &args, value);
        }
    }
    for (argv) |arg| try appendOwned(allocator, &args, try allocator.dupe(u8, arg));
    return .{ .argv = try args.toOwnedSlice(allocator) };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, argv: []const []const u8, input: ?[]const u8, cwd: ?[]const u8) !void {
    return runWithCwd(allocator, io, environ, argv, input, if (cwd) |path| .{ .path = path } else .inherit);
}

pub fn runWithCwd(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, argv: []const []const u8, input: ?[]const u8, cwd: std.process.Child.Cwd) !void {
    var cmd = try command(allocator, environ, argv);
    defer cmd.deinit(allocator);
    var environment = try environ.createMap(allocator);
    defer environment.deinit();
    var child = try std.process.spawn(io, .{
        .argv = cmd.asConst(),
        .environ_map = &environment,
        .cwd = cwd,
        .stdin = if (input != null) .pipe else .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    if (input) |bytes| {
        try child.stdin.?.writeStreamingAll(io, bytes);
        child.stdin.?.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CallerOperationFailed;
}

pub fn makePath(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, path: []const u8) !void {
    try run(allocator, io, environ, &.{ "/usr/bin/mkdir", "-p", "--", path }, null, null);
}

pub fn deleteTree(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, path: []const u8) !void {
    try run(allocator, io, environ, &.{ "/usr/bin/rm", "-rf", "--", path }, null, null);
}

/// All opens, including the temporary file, happen after the credential drop.
/// No shell interpolation or root-created destination descriptors are used.
pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try makePath(allocator, io, environ, parent);
    var random: [16]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.shelly-{s}", .{ path, suffix });
    defer allocator.free(temporary);
    defer run(allocator, io, environ, &.{ "/usr/bin/rm", "-f", "--", temporary }, null, null) catch {};
    try run(allocator, io, environ, &.{ "/usr/bin/tee", "--", temporary }, bytes, null);
    try run(allocator, io, environ, &.{ "/usr/bin/mv", "-fT", "--", temporary, path }, null, null);
}

test "caller IO writes and replaces files without changing parent credentials" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const uid = std.c.geteuid();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "new cache", "Shelly", "feed" });
    defer a.free(path);
    try writeFile(a, io, .empty, path, "first");
    try writeFile(a, io, .empty, path, "second\x00payload");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("second\x00payload", bytes);
    try std.testing.expectEqual(uid, std.c.geteuid());
}

// Enabled only by scripts/test-caller-cache-ownership.sh in a private namespace.
test "caller IO real elevated ownership and denied root fallback" {
    const stage = std.testing.environ.getPosix("SHELLY_TEST_CALLER_IO_DIRECTORY") orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectEqual(0, std.c.geteuid());
    const user = (try accounts.byName(a, "nobody")).?;
    defer user.deinit(a);
    const uid = try std.fmt.allocPrint(a, "{d}", .{user.uid});
    defer a.free(uid);
    const path = try std.fs.path.join(a, &.{ user.home, ".cache", "Shelly", "feed" });
    defer a.free(path);
    const denied = try std.fs.path.join(a, &.{ stage, "root-only", "must-not-exist" });
    defer a.free(denied);
    for ([_][]const u8{ "SUDO_USER", "DOAS_USER", "PKEXEC_UID" }) |marker| {
        var map = std.process.Environ.Map.init(a);
        defer map.deinit();
        try map.put(marker, if (std.mem.eql(u8, marker, "PKEXEC_UID")) uid else user.username);
        try map.put("HOME", "/root");
        const env: std.process.Environ = .{ .block = try map.createPosixBlock(a, .{}) };
        defer env.block.deinit(a);
        const home = try accounts.callerHome(a, env);
        defer a.free(home);
        try std.testing.expectEqualStrings(user.home, home);
        try writeFile(a, io, env, path, marker);
        try std.testing.expectError(error.CallerOperationFailed, makePath(a, io, env, denied));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, denied, .{}));
        const result = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/stat", "-c", "%u", "--", path } });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        try std.testing.expectEqualStrings(uid, std.mem.trim(u8, result.stdout, "\n"));
        var identity_command = try command(a, env, &.{ "/usr/bin/id", "-G" });
        defer identity_command.deinit(a);
        const identity = try std.process.run(a, io, .{ .argv = identity_command.asConst() });
        defer a.free(identity.stdout);
        defer a.free(identity.stderr);
        try std.testing.expect(identity.term == .exited and identity.term.exited == 0);
        try std.testing.expect(std.mem.indexOf(u8, identity.stdout, "65533") != null);
        try std.testing.expectEqual(0, std.c.geteuid());
    }
    var custom_map = std.process.Environ.Map.init(a);
    defer custom_map.deinit();
    try custom_map.put("SUDO_USER", user.username);
    const custom_cache = try std.fs.path.join(a, &.{ user.home, "custom cache" });
    defer a.free(custom_cache);
    try custom_map.put("XDG_CACHE_HOME", custom_cache);
    const custom: std.process.Environ = .{ .block = try custom_map.createPosixBlock(a, .{}) };
    defer custom.block.deinit(a);
    try run(a, io, custom, &.{ "/bin/sh", "-ec", "mkdir -p \"$XDG_CACHE_HOME/Shelly\"; printf '%s' \"$HOME\" > \"$XDG_CACHE_HOME/Shelly/home\"" }, null, null);
    const home_file = try std.fs.path.join(a, &.{ custom_cache, "Shelly", "home" });
    defer a.free(home_file);
    const home_bytes = try std.Io.Dir.cwd().readFileAlloc(io, home_file, a, .limited(4096));
    defer a.free(home_bytes);
    try std.testing.expectEqualStrings(user.home, home_bytes);
    try deleteTree(a, io, custom, custom_cache);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, custom_cache, .{}));
    var invalid_map = std.process.Environ.Map.init(a);
    defer invalid_map.deinit();
    try invalid_map.put("SUDO_USER", "shelly-missing-caller-7419");
    const invalid: std.process.Environ = .{ .block = try invalid_map.createPosixBlock(a, .{}) };
    defer invalid.block.deinit(a);
    try std.testing.expectError(error.InvokingUserUnavailable, makePath(a, io, invalid, denied));
    const root_home = try accounts.callerHome(a, .empty);
    defer a.free(root_home);
    const root_path = try std.fs.path.join(a, &.{ root_home, ".cache", "Shelly", "feed" });
    defer a.free(root_path);
    try writeFile(a, io, .empty, root_path, "direct root");
}
