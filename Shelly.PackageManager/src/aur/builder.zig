const std = @import("std");
const user_account = @import("user_account");
const operation_api = @import("operation_context");

pub const ProcessResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const StreamKind = enum {
    stdout,
    stderr,
};

pub const LineHandler = struct {
    function: *const fn (data: ?*anyopaque, stream: StreamKind, line: []const u8) void,
    data: ?*anyopaque = null,

    fn call(self: LineHandler, stream: StreamKind, line: []const u8) void {
        self.function(self.data, stream, line);
    }
};

pub const BuildEnvironment = struct {
    cppflags: ?[]const []const u8 = null,
    cflags: ?[]const []const u8 = null,
    cxxflags: ?[]const []const u8 = null,
    ldflags: ?[]const []const u8 = null,
    ltoflags: ?[]const []const u8 = null,
    makeflags: ?[]const []const u8 = null,
    chost: ?[]const u8 = null,
    distcc_hosts: ?[]const []const u8 = null,
    /// One build-scoped timestamp shared with every PKGBUILD subprocess and
    /// package metadata writer, matching makepkg's SOURCE_DATE_EPOCH model.
    source_date_epoch: ?i64 = null,
    ccache: bool = false,
    distcc: bool = false,
};

pub const OwnedCommand = struct {
    argv: [][]u8,

    pub fn deinit(self: *OwnedCommand, allocator: std.mem.Allocator) void {
        for (self.argv) |argument| allocator.free(argument);
        allocator.free(self.argv);
        self.* = undefined;
    }

    pub fn asConst(self: *const OwnedCommand) []const []const u8 {
        return @ptrCast(self.argv);
    }
};

pub fn directCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    arguments: []const []const u8,
) !OwnedCommand {
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }
    try appendOwned(allocator, &argv, &.{command});
    try appendOwned(allocator, &argv, arguments);
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
) !ProcessResult {
    return runWithEnvironmentMap(allocator, io, argv, working_directory, timeout_seconds, null);
}

pub fn runWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
) !ProcessResult {
    var environ_map = try executionEnvironment(allocator, environ);
    defer environ_map.deinit();
    return runWithEnvironmentMap(allocator, io, argv, working_directory, timeout_seconds, &environ_map);
}

pub fn runStreamingWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
    line_handler: LineHandler,
) !u8 {
    return runStreamingWithEnvironmentOperation(
        allocator,
        io,
        environ,
        argv,
        working_directory,
        timeout_seconds,
        line_handler,
        null,
    );
}

pub fn runStreamingWithEnvironmentOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
    line_handler: LineHandler,
    operation: ?*const operation_api.Operation,
) !u8 {
    return runStreamingWithBuildEnvironmentOperation(
        allocator,
        io,
        environ,
        null,
        argv,
        working_directory,
        timeout_seconds,
        line_handler,
        operation,
    );
}

pub fn runStreamingWithBuildEnvironmentOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    build_environment: ?BuildEnvironment,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
    line_handler: LineHandler,
    operation: ?*const operation_api.Operation,
) !u8 {
    var environ_map = if (build_environment) |build|
        try executionEnvironmentWithBuild(allocator, environ, build)
    else
        try executionEnvironment(allocator, environ);
    defer environ_map.deinit();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (working_directory) |path| .{ .path = path } else .inherit,
        .environ_map = &environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const poll_for_cancellation = operation != null;
    const timeout: std.Io.Timeout = if (poll_for_cancellation)
        .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(250) } }
    else if (timeout_seconds) |seconds|
        .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(seconds) } }
    else
        .none;
    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    read_loop: while (true) {
        multi_reader.fill(4096, timeout) catch |err| switch (err) {
            error.EndOfStream => break :read_loop,
            error.Timeout => {
                if (operation) |active_operation| {
                    if (active_operation.isCancelled()) {
                        child.kill(io);
                        return error.Cancelled;
                    }
                    if (timeout_seconds) |seconds| {
                        const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - start;
                        if (elapsed >= @as(i96, seconds) * std.time.ns_per_s) return error.Timeout;
                    }
                    continue :read_loop;
                }
                return error.Timeout;
            },
            else => |other| return other,
        };
        if (operation) |active_operation| {
            if (active_operation.isCancelled()) {
                child.kill(io);
                return error.Cancelled;
            }
        }
        drainLines(multi_reader.reader(0), .stdout, false, line_handler);
        drainLines(multi_reader.reader(1), .stderr, false, line_handler);
    }
    try multi_reader.checkAnyError();
    drainLines(multi_reader.reader(0), .stdout, true, line_handler);
    drainLines(multi_reader.reader(1), .stderr, true, line_handler);

    if (operation) |active_operation| {
        if (active_operation.isCancelled()) {
            child.kill(io);
            return error.Cancelled;
        }
    }
    return switch ((try child.wait(io))) {
        .exited => |code| code,
        else => 255,
    };
}

fn drainLines(reader: *std.Io.Reader, stream: StreamKind, flush_tail: bool, line_handler: LineHandler) void {
    while (std.mem.indexOfAny(u8, reader.buffered(), "\r\n")) |line_end| {
        const line = reader.buffered()[0..line_end];

        if (std.mem.trim(u8, line, " \t").len != 0) {
            line_handler.call(stream, line);
        }

        reader.toss(line_end + 1);
    }

    if (flush_tail and reader.bufferedLen() != 0) {
        const len = reader.bufferedLen();
        const line = std.mem.trimEnd(u8, reader.buffered(), "\r");
        if (line.len != 0) line_handler.call(stream, line);
        reader.toss(len);
    }
}

fn runWithEnvironmentMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
    environ_map: ?*const std.process.Environ.Map,
) !ProcessResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (working_directory) |path| .{ .path = path } else .inherit,
        .environ_map = environ_map,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
        .timeout = if (timeout_seconds) |seconds|
            .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(seconds) } }
        else
            .none,
    });
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn executionEnvironment(allocator: std.mem.Allocator, environ: std.process.Environ) !std.process.Environ.Map {
    var environ_map = try environ.createMap(allocator);
    errdefer environ_map.deinit();
    const path = try buildExecutionPath(allocator, environ);
    defer allocator.free(path);
    try environ_map.put("PATH", path);
    return environ_map;
}

pub fn executionEnvironmentWithBuild(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    build: BuildEnvironment,
) !std.process.Environ.Map {
    var environ_map = try executionEnvironment(allocator, environ);
    errdefer environ_map.deinit();

    try putJoinedOrRemove(allocator, &environ_map, "CPPFLAGS", build.cppflags);
    try putJoinedOrRemove(allocator, &environ_map, "CFLAGS", build.cflags);
    try putJoinedOrRemove(allocator, &environ_map, "CXXFLAGS", build.cxxflags);
    try putJoinedOrRemove(allocator, &environ_map, "LDFLAGS", build.ldflags);
    try putJoinedOrRemove(allocator, &environ_map, "LTOFLAGS", build.ltoflags);
    try putJoinedOrRemove(allocator, &environ_map, "MAKEFLAGS", build.makeflags);
    try putScalarOrRemove(&environ_map, "CHOST", build.chost);
    try putJoinedOrRemove(
        allocator,
        &environ_map,
        "DISTCC_HOSTS",
        if (build.distcc) build.distcc_hosts else null,
    );
    if (build.source_date_epoch) |epoch| {
        var epoch_buffer: [20]u8 = undefined;
        const epoch_text = try std.fmt.bufPrint(&epoch_buffer, "{d}", .{epoch});
        try environ_map.put("SOURCE_DATE_EPOCH", epoch_text);
    }

    const base_path = environ_map.get("PATH") orelse "";
    var prefixed_path: std.ArrayList(u8) = .empty;
    defer prefixed_path.deinit(allocator);
    if (build.ccache) try prefixed_path.appendSlice(allocator, "/usr/lib/ccache/bin:");
    if (build.distcc) try prefixed_path.appendSlice(allocator, "/usr/lib/distcc/bin:");
    try prefixed_path.appendSlice(allocator, base_path);
    try environ_map.put("PATH", prefixed_path.items);
    return environ_map;
}

fn putJoinedOrRemove(
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    name: []const u8,
    values: ?[]const []const u8,
) !void {
    if (values) |configured| {
        const joined = try std.mem.join(allocator, " ", configured);
        defer allocator.free(joined);
        try environ_map.put(name, joined);
    } else {
        _ = environ_map.swapRemove(name);
    }
}

fn putScalarOrRemove(
    environ_map: *std.process.Environ.Map,
    name: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |configured|
        try environ_map.put(name, configured)
    else
        _ = environ_map.swapRemove(name);
}

pub fn buildExecutionPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin";
    const path = environ.getPosix("PATH") orelse default_path;
    if (std.mem.indexOf(u8, path, "core_perl") != null) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(
        allocator,
        "/usr/bin/core_perl:/usr/bin/vendor_perl:/usr/bin/site_perl:{s}",
        .{path},
    );
}

pub fn resolveUsernameForUid(
    allocator: std.mem.Allocator,
    _: std.Io,
    uid: []const u8,
) ![]u8 {
    const account = (try user_account.byUidText(allocator, uid)) orelse return error.InvokingUserUnavailable;
    defer account.deinit(allocator);
    return allocator.dupe(u8, account.username);
}

pub fn resolveInvokingUserHome(
    allocator: std.mem.Allocator,
    _: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    const account = if (environ.getPosix("SUDO_USER")) |user|
        (if (user.len != 0 and !std.mem.eql(u8, user, "root")) try user_account.byName(allocator, user) else null)
    else if (environ.getPosix("DOAS_USER")) |user|
        (if (user.len != 0 and !std.mem.eql(u8, user, "root")) try user_account.byName(allocator, user) else null)
    else if (environ.getPosix("PKEXEC_UID")) |uid|
        try user_account.byUidText(allocator, uid)
    else
        null;
    if (account) |found| {
        defer found.deinit(allocator);
        if (found.home.len != 0) return allocator.dupe(u8, found.home);
    }
    const fallback = environ.getPosix("HOME") orelse return error.HomeNotSet;
    return allocator.dupe(u8, fallback);
}

pub fn invokingUserCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    command: []const u8,
    arguments: []const []const u8,
) !OwnedCommand {
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }

    if (environ.getPosix("SUDO_USER")) |sudo_user| {
        try appendOwned(allocator, &argv, &.{ "sudo", "--preserve-env=PATH", "-u", sudo_user, command });
    } else if (environ.getPosix("DOAS_USER")) |doas_user| {
        try appendOwned(allocator, &argv, &.{ "/usr/bin/runuser", "-u", doas_user, "-w", "PATH", "--", command });
    } else if (environ.getPosix("PKEXEC_UID")) |uid| {
        const username = try resolveUsernameForUid(allocator, io, uid);
        defer allocator.free(username);
        try appendOwned(allocator, &argv, &.{ "/usr/bin/runuser", "-u", username, "-w", "PATH", "--", command });
    } else try appendOwned(allocator, &argv, &.{command});

    try appendOwned(allocator, &argv, arguments);
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

/// Builds a command that executes as the original non-root caller with a
/// minimal user environment. This is the privilege boundary used for running
/// reviewed PKGBUILD code from an elevated package operation.
pub fn invokingUserCleanCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    command: []const u8,
    arguments: []const []const u8,
) !OwnedCommand {
    const username = try invokingUsername(allocator, io, environ);
    defer allocator.free(username);
    const account = (try user_account.byName(allocator, username)) orelse return error.InvokingUserUnavailable;
    defer account.deinit(allocator);
    if (account.uid == 0 or account.home.len == 0) return error.InvokingUserUnavailable;
    var uid_buffer: [10]u8 = undefined;
    const uid = try std.fmt.bufPrint(&uid_buffer, "{d}", .{account.uid});
    const path = try buildExecutionPath(allocator, environ);
    defer allocator.free(path);

    return cleanUserCommand(
        allocator,
        username,
        account.home,
        uid,
        path,
        environ.getPosix("SOURCE_DATE_EPOCH"),
        command,
        arguments,
    );
}

fn cleanUserCommand(
    allocator: std.mem.Allocator,
    username: []const u8,
    home: []const u8,
    uid: []const u8,
    path: []const u8,
    source_date_epoch: ?[]const u8,
    command: []const u8,
    arguments: []const []const u8,
) !OwnedCommand {
    const home_environment = try std.fmt.allocPrint(allocator, "HOME={s}", .{home});
    defer allocator.free(home_environment);
    const config_environment = try std.fmt.allocPrint(allocator, "XDG_CONFIG_HOME={s}/.config", .{home});
    defer allocator.free(config_environment);
    const data_environment = try std.fmt.allocPrint(allocator, "XDG_DATA_HOME={s}/.local/share", .{home});
    defer allocator.free(data_environment);
    const cache_environment = try std.fmt.allocPrint(allocator, "XDG_CACHE_HOME={s}/.cache", .{home});
    defer allocator.free(cache_environment);
    const bin_environment = try std.fmt.allocPrint(allocator, "XDG_BIN_HOME={s}/.local/bin", .{home});
    defer allocator.free(bin_environment);
    const runtime_environment = try std.fmt.allocPrint(allocator, "XDG_RUNTIME_DIR=/run/user/{s}", .{uid});
    defer allocator.free(runtime_environment);
    const bus_environment = try std.fmt.allocPrint(
        allocator,
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{s}/bus",
        .{uid},
    );
    defer allocator.free(bus_environment);
    const path_environment = try std.fmt.allocPrint(allocator, "PATH={s}", .{path});
    defer allocator.free(path_environment);
    const source_date_epoch_environment = if (source_date_epoch) |epoch|
        try std.fmt.allocPrint(allocator, "SOURCE_DATE_EPOCH={s}", .{epoch})
    else
        null;
    defer if (source_date_epoch_environment) |value| allocator.free(value);

    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }
    try appendOwned(allocator, &argv, &.{
        "/usr/bin/runuser",
        "-u",
        username,
        "--",
        "env",
        "-i",
        home_environment,
        config_environment,
        data_environment,
        cache_environment,
        bin_environment,
        runtime_environment,
        bus_environment,
        path_environment,
    });
    if (source_date_epoch_environment) |value|
        try appendOwned(allocator, &argv, &.{value});
    try appendOwned(allocator, &argv, &.{command});
    try appendOwned(allocator, &argv, arguments);
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

pub fn invokingUsername(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    if (environ.getPosix("SUDO_USER")) |username|
        return validateInvokingUsername(allocator, io, username);
    if (environ.getPosix("DOAS_USER")) |username|
        return validateInvokingUsername(allocator, io, username);
    if (environ.getPosix("PKEXEC_UID")) |uid| {
        const account = (try user_account.byUidText(allocator, uid)) orelse return error.InvokingUserUnavailable;
        defer account.deinit(allocator);
        if (account.uid == 0 or account.username.len == 0 or std.mem.eql(u8, account.username, "root") or std.mem.eql(u8, account.username, "0"))
            return error.InvokingUserUnavailable;
        return allocator.dupe(u8, account.username);
    }
    return error.InvokingUserUnavailable;
}

fn validateInvokingUsername(allocator: std.mem.Allocator, _: std.Io, username: []const u8) ![]u8 {
    if (username.len == 0 or std.mem.eql(u8, username, "root") or std.mem.eql(u8, username, "0"))
        return error.InvokingUserUnavailable;
    const account = (try user_account.byName(allocator, username)) orelse return error.InvokingUserUnavailable;
    defer account.deinit(allocator);
    if (account.uid == 0) return error.InvokingUserUnavailable;
    return allocator.dupe(u8, account.username);
}

fn appendOwned(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), values: []const []const u8) !void {
    for (values) |value| try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn makechrootpkgCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    chroot_path: []const u8,
) !OwnedCommand {
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }
    try appendOwned(allocator, &argv, &.{ "makechrootpkg", "-c", "-r", chroot_path });
    if (environ.getPosix("SUDO_USER")) |user| {
        try appendOwned(allocator, &argv, &.{ "-U", user });
    } else if (environ.getPosix("PKEXEC_UID")) |uid| {
        const user = try resolveUsernameForUid(allocator, io, uid);
        defer allocator.free(user);
        if (user.len != 0) try appendOwned(allocator, &argv, &.{ "-U", user });
    }
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

pub const BuildProgress = struct {
    percent: u8,
    message: []const u8,
};

pub fn parseBuildProgress(line: []const u8) ?BuildProgress {
    const open = std.mem.indexOfScalar(u8, line, '[') orelse return null;
    const percent_sign = std.mem.indexOfPos(u8, line, open + 1, "%") orelse return null;
    const close = std.mem.indexOfPos(u8, line, percent_sign + 1, "]") orelse return null;
    const percent_text = std.mem.trim(u8, line[open + 1 .. percent_sign], " \t");
    const percent = std.fmt.parseInt(u8, percent_text, 10) catch return null;
    if (percent > 100) return null;
    return .{
        .percent = percent,
        .message = std.mem.trim(u8, line[close + 1 ..], " \t"),
    };
}

pub fn selectBuiltPackageFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    package_name: []const u8,
) ![][]u8 {
    return selectBuiltPackageFilesForNames(
        allocator,
        io,
        directory_path,
        &.{package_name},
        &.{package_name},
    );
}

pub fn selectBuiltPackageFilesForNames(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    requested_names: []const []const u8,
    package_names: []const []const u8,
) ![][]u8 {
    var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isBuiltPackageFile(entry.name)) continue;

        // Split-package names may prefix one another (for example `demo` and
        // `demo-docs`). Classifying against the longest known package name
        // prevents selecting an unrequested sibling as `demo`.
        var matched_name: ?[]const u8 = null;
        for (package_names) |name| {
            if (entry.name.len <= name.len or entry.name[name.len] != '-' or
                !std.mem.startsWith(u8, entry.name, name)) continue;
            if (matched_name == null or name.len > matched_name.?.len) matched_name = name;
        }
        const package = matched_name orelse continue;
        var requested = false;
        for (requested_names) |name| {
            if (std.mem.eql(u8, name, package)) {
                requested = true;
                break;
            }
        }
        if (!requested) continue;
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ directory_path, entry.name }));
    }
    return paths.toOwnedSlice(allocator);
}

pub fn isBuiltPackageFile(file_name: []const u8) bool {
    return isPackageArchiveArtifact(file_name) and
        !std.mem.endsWith(u8, file_name, ".sig");
}

pub fn isPackageArchiveArtifact(file_name: []const u8) bool {
    return std.mem.indexOf(u8, file_name, ".pkg.tar.") != null;
}

pub fn deinitPaths(allocator: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

test "build progress parser recognizes makepkg percentage lines" {
    const progress = parseBuildProgress("[ 42%] Compiling source files").?;
    try std.testing.expectEqual(@as(u8, 42), progress.percent);
    try std.testing.expectEqualStrings("Compiling source files", progress.message);
    try std.testing.expect(parseBuildProgress("ordinary output") == null);
}

test "execution PATH adds Arch Perl paths exactly once" {
    const path = try buildExecutionPath(std.testing.allocator, std.testing.environ);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/usr/bin/core_perl") != null);

    var environ_map = try executionEnvironment(std.testing.allocator, std.testing.environ);
    defer environ_map.deinit();
    try std.testing.expectEqualStrings(path, environ_map.get("PATH").?);
}

test "build environment exports flags hosts and compiler wrapper paths" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PATH", "/usr/bin:/bin");
    const environ: std.process.Environ = .{
        .block = try environ_map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer environ.block.deinit(std.testing.allocator);

    var effective = try executionEnvironmentWithBuild(std.testing.allocator, environ, .{
        .cppflags = &.{"-D_FORTIFY_SOURCE=3"},
        .cflags = &.{ "-O3", "-pipe" },
        .cxxflags = &.{"-O3"},
        .ldflags = &.{"-Wl,-z,now"},
        .ltoflags = &.{"-flto=auto"},
        .makeflags = &.{"-j8"},
        .chost = "x86_64-pc-linux-gnu",
        .distcc_hosts = &.{ "builder/8", "localhost/2" },
        .source_date_epoch = 1_700_000_000,
        .ccache = true,
        .distcc = true,
    });
    defer effective.deinit();

    try std.testing.expectEqualStrings("-D_FORTIFY_SOURCE=3", effective.get("CPPFLAGS").?);
    try std.testing.expectEqualStrings("-O3 -pipe", effective.get("CFLAGS").?);
    try std.testing.expectEqualStrings("-j8", effective.get("MAKEFLAGS").?);
    try std.testing.expectEqualStrings("builder/8 localhost/2", effective.get("DISTCC_HOSTS").?);
    try std.testing.expectEqualStrings("1700000000", effective.get("SOURCE_DATE_EPOCH").?);
    try std.testing.expect(std.mem.startsWith(u8, effective.get("PATH").?, "/usr/lib/ccache/bin:/usr/lib/distcc/bin:"));
}

test "disabled build environment removes inherited flags and hosts" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("CFLAGS", "ambient flags");
    try environ_map.put("MAKEFLAGS", "ambient make flags");
    try environ_map.put("DISTCC_HOSTS", "ambient host");
    const environ: std.process.Environ = .{
        .block = try environ_map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer environ.block.deinit(std.testing.allocator);

    var effective = try executionEnvironmentWithBuild(std.testing.allocator, environ, .{
        .chost = "x86_64-pc-linux-gnu",
    });
    defer effective.deinit();
    try std.testing.expect(effective.get("CFLAGS") == null);
    try std.testing.expect(effective.get("MAKEFLAGS") == null);
    try std.testing.expect(effective.get("DISTCC_HOSTS") == null);
    try std.testing.expectEqualStrings("x86_64-pc-linux-gnu", effective.get("CHOST").?);
}

test "VCS build commands replicate invoking-user behavior" {
    var command = try makechrootpkgCommand(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        "/var/lib/shelly/chroot",
    );
    defer command.deinit(std.testing.allocator);
    var command_index: ?usize = null;
    for (command.argv, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "makechrootpkg")) command_index = index;
    }
    const index = command_index orelse return error.MissingMakechrootpkgCommand;
    try std.testing.expectEqualStrings("-c", command.argv[index + 1]);
    try std.testing.expectEqualStrings("-r", command.argv[index + 2]);
    try std.testing.expectEqualStrings("/var/lib/shelly/chroot", command.argv[index + 3]);
}

test "NSS invoking-user commands resolve all elevators without HOME" {
    const allocator = std.testing.allocator;
    const account = (try user_account.byName(allocator, "nobody")) orelse return error.SkipZigTest;
    defer account.deinit(allocator);
    const uid = try std.fmt.allocPrint(allocator, "{d}", .{account.uid});
    defer allocator.free(uid);
    const resolved = try resolveUsernameForUid(allocator, std.testing.io, uid);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(account.username, resolved);
    for ([_][]const u8{ "SUDO_USER", "DOAS_USER", "PKEXEC_UID" }) |marker| {
        var environment = std.process.Environ.Map.init(allocator);
        defer environment.deinit();
        try environment.put(marker, if (std.mem.eql(u8, marker, "PKEXEC_UID")) uid else account.username);
        const environ: std.process.Environ = .{ .block = try environment.createPosixBlock(allocator, .{}) };
        defer environ.block.deinit(allocator);
        const home = try resolveInvokingUserHome(allocator, std.testing.io, environ);
        defer allocator.free(home);
        try std.testing.expectEqualStrings(account.home, home);
        var command = try invokingUserCleanCommand(allocator, std.testing.io, environ, "shelly", &.{"build"});
        defer command.deinit(allocator);
        try std.testing.expectEqualStrings(account.username, command.argv[2]);
        const expected_home = try std.fmt.allocPrint(allocator, "HOME={s}", .{account.home});
        defer allocator.free(expected_home);
        try std.testing.expectEqualStrings(expected_home, command.argv[6]);
        const expected_runtime = try std.fmt.allocPrint(allocator, "XDG_RUNTIME_DIR=/run/user/{s}", .{uid});
        defer allocator.free(expected_runtime);
        try std.testing.expectEqualStrings(expected_runtime, command.argv[11]);
    }
}

test "NSS invoking-user validation rejects root and unresolved accounts" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "root", "0", "", "shelly-nonexistent-user-1843" }) |name|
        try std.testing.expectError(error.InvokingUserUnavailable, validateInvokingUsername(allocator, std.testing.io, name));
    for ([_][]const u8{ "0", "000", "invalid", "4294967296" }) |uid| {
        var environment = std.process.Environ.Map.init(allocator);
        defer environment.deinit();
        try environment.put("PKEXEC_UID", uid);
        const environ: std.process.Environ = .{ .block = try environment.createPosixBlock(allocator, .{}) };
        defer environ.block.deinit(allocator);
        try std.testing.expectError(error.InvokingUserUnavailable, invokingUserCleanCommand(allocator, std.testing.io, environ, "shelly", &.{}));
    }
}

test "clean invoking-user build command drops the elevated environment" {
    var command = try cleanUserCommand(
        std.testing.allocator,
        "zoey",
        "/home/zoey",
        "1000",
        "/usr/bin:/bin",
        "1700000000",
        "/usr/bin/shelly",
        &.{ "build", "--coordinator-child", "/tmp/PKGBUILD" },
    );
    defer command.deinit(std.testing.allocator);
    const expected = [_][]const u8{
        "/usr/bin/runuser",
        "-u",
        "zoey",
        "--",
        "env",
        "-i",
        "HOME=/home/zoey",
        "XDG_CONFIG_HOME=/home/zoey/.config",
        "XDG_DATA_HOME=/home/zoey/.local/share",
        "XDG_CACHE_HOME=/home/zoey/.cache",
        "XDG_BIN_HOME=/home/zoey/.local/bin",
        "XDG_RUNTIME_DIR=/run/user/1000",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
        "PATH=/usr/bin:/bin",
        "SOURCE_DATE_EPOCH=1700000000",
        "/usr/bin/shelly",
        "build",
        "--coordinator-child",
        "/tmp/PKGBUILD",
    };
    try std.testing.expectEqual(expected.len, command.argv.len);
    for (expected, command.argv) |wanted, actual|
        try std.testing.expectEqualStrings(wanted, actual);
}

test "built package selection mirrors split-package and stale-output safeguards" {
    var matching = std.testing.tmpDir(.{});
    defer matching.cleanup();
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-1-1-x86_64.pkg.tar.zst", .data = "" });
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-docs-1-1-any.pkg.tar.zst", .data = "" });
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-1-1-x86_64.pkg.tar.zst.sig", .data = "" });
    const matching_path = try matching.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(matching_path);
    const split_files = try selectBuiltPackageFilesForNames(
        std.testing.allocator,
        std.testing.io,
        matching_path,
        &.{"demo"},
        &.{ "demo", "demo-docs" },
    );
    defer deinitPaths(std.testing.allocator, split_files);
    try std.testing.expectEqual(@as(usize, 1), split_files.len);
    try std.testing.expect(std.mem.endsWith(u8, split_files[0], "demo-1-1-x86_64.pkg.tar.zst"));

    const all_split_files = try selectBuiltPackageFilesForNames(
        std.testing.allocator,
        std.testing.io,
        matching_path,
        &.{ "demo", "demo-docs" },
        &.{ "demo", "demo-docs" },
    );
    defer deinitPaths(std.testing.allocator, all_split_files);
    try std.testing.expectEqual(@as(usize, 2), all_split_files.len);

    var ambiguous = std.testing.tmpDir(.{});
    defer ambiguous.cleanup();
    try ambiguous.dir.writeFile(std.testing.io, .{ .sub_path = "one-1-1-any.pkg.tar.zst", .data = "" });
    try ambiguous.dir.writeFile(std.testing.io, .{ .sub_path = "two-1-1-any.pkg.tar.zst", .data = "" });
    const ambiguous_path = try ambiguous.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ambiguous_path);
    const no_match = try selectBuiltPackageFiles(std.testing.allocator, std.testing.io, ambiguous_path, "demo");
    defer deinitPaths(std.testing.allocator, no_match);
    try std.testing.expectEqual(@as(usize, 0), no_match.len);

    try std.testing.expect(isBuiltPackageFile("demo.pkg.tar.zst"));
    try std.testing.expect(!isBuiltPackageFile("demo.pkg.tar.zst.sig"));
    try std.testing.expect(isPackageArchiveArtifact("demo.pkg.tar.zst.sig"));
}

test "streaming process execution forwards stdout stderr and a final unterminated line" {
    const Capture = struct {
        stdout_buffer: [64]u8 = undefined,
        stdout_len: usize = 0,
        stderr_buffer: [64]u8 = undefined,
        stderr_len: usize = 0,

        fn append(target: []u8, len: *usize, line: []const u8) void {
            if (len.* != 0 and len.* < target.len) {
                target[len.*] = '|';
                len.* += 1;
            }
            const amount = @min(line.len, target.len - len.*);
            @memcpy(target[len.*..][0..amount], line[0..amount]);
            len.* += amount;
        }

        fn onLine(data: ?*anyopaque, stream: StreamKind, line: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            switch (stream) {
                .stdout => append(&self.stdout_buffer, &self.stdout_len, line),
                .stderr => append(&self.stderr_buffer, &self.stderr_len, line),
            }
        }
    };

    var capture = Capture{};
    const exit_code = try runStreamingWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        &.{ "sh", "-c", "printf 'first\\nlast'; printf 'problem\\n' >&2" },
        null,
        null,
        .{ .function = Capture.onLine, .data = &capture },
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("first|last", capture.stdout_buffer[0..capture.stdout_len]);
    try std.testing.expectEqualStrings("problem", capture.stderr_buffer[0..capture.stderr_len]);
}

test "streaming process execution delivers output before the child exits" {
    const Capture = struct {
        io: std.Io,
        acknowledgement_path: []const u8,
        saw_first: bool = false,
        saw_second: bool = false,

        fn onLine(data: ?*anyopaque, stream: StreamKind, line: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            if (stream != .stdout) return;
            if (std.mem.eql(u8, line, "first")) {
                self.saw_first = true;
                var acknowledgement = std.Io.Dir.cwd().createFile(
                    self.io,
                    self.acknowledgement_path,
                    .{},
                ) catch return;
                acknowledgement.close(self.io);
            } else if (std.mem.eql(u8, line, "second")) {
                self.saw_second = true;
            }
        }
    };

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const temporary_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temporary_path);
    const acknowledgement_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "acknowledged" });
    defer std.testing.allocator.free(acknowledgement_path);

    var capture = Capture{
        .io = std.testing.io,
        .acknowledgement_path = acknowledgement_path,
    };
    const exit_code = try runStreamingWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        &.{
            "sh",
            "-c",
            "printf 'first\\n'; i=0; while [ ! -e \"$1\" ] && [ \"$i\" -lt 100 ]; do sleep 0.01; i=$((i + 1)); done; [ -e \"$1\" ] || exit 9; printf 'second\\n'",
            "sh",
            acknowledgement_path,
        },
        null,
        null,
        .{ .function = Capture.onLine, .data = &capture },
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(capture.saw_first);
    try std.testing.expect(capture.saw_second);
}

test "streaming process execution terminates when the shared operation is cancelled" {
    const Capture = struct {
        fn onLine(_: ?*anyopaque, _: StreamKind, _: []const u8) void {}
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const marker = try std.fs.path.join(std.testing.allocator, &.{ directory, "child-started" });
    defer std.testing.allocator.free(marker);

    var context = operation_api.OperationContext.init(std.testing.allocator, io);
    defer context.deinit();
    var operation = context.begin(.{ .backend = .aur, .kind = .build, .subject = "cancelled-build" });
    defer operation.finish(.cancelled);
    var future = try io.concurrent(runStreamingWithEnvironmentOperation, .{
        std.testing.allocator,
        io,
        std.testing.environ,
        &.{ "sh", "-c", "touch \"$1\"; exec sleep 30", "sh", marker },
        null,
        null,
        LineHandler{ .function = Capture.onLine },
        &operation,
    });
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        std.Io.Dir.cwd().access(io, marker, .{}) catch {
            io.sleep(.fromMilliseconds(5), .awake) catch {};
            continue;
        };
        break;
    }
    try std.testing.expect(attempts < 200);
    context.cancel();
    try std.testing.expectError(error.Cancelled, future.await(io));
}
