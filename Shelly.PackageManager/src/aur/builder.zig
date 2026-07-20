const std = @import("std");
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
    var environ_map = try executionEnvironment(allocator, environ);
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
    while (std.mem.indexOfScalar(u8, reader.buffered(), '\n')) |line_end| {
        const line = std.mem.trimEnd(u8, reader.buffered()[0..line_end], "\r");
        if (line.len != 0) line_handler.call(stream, line);
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

pub fn resolveUsernameForUidFromPasswd(uid: []const u8, passwd: []const u8) []const u8 {
    if (uid.len == 0) return uid;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, ':');
        const username = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const field_uid = fields.next() orelse continue;
        if (std.mem.eql(u8, uid, field_uid)) return username;
    }
    return uid;
}

pub fn resolveUsernameForUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    uid: []const u8,
) ![]u8 {
    if (uid.len == 0) return allocator.dupe(u8, uid);
    const passwd = std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", allocator, .limited(4 * 1024 * 1024)) catch
        return allocator.dupe(u8, uid);
    defer allocator.free(passwd);
    return allocator.dupe(u8, resolveUsernameForUidFromPasswd(uid, passwd));
}

pub fn resolveInvokingUserHome(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]u8 {
    const fallback = environ.getPosix("HOME") orelse return error.HomeNotSet;
    const passwd = std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", allocator, .limited(4 * 1024 * 1024)) catch
        return allocator.dupe(u8, fallback);
    defer allocator.free(passwd);

    if (environ.getPosix("SUDO_USER")) |user| {
        if (user.len != 0 and !std.mem.eql(u8, user, "root")) {
            if (homeFromPasswd(passwd, user, null)) |home| return allocator.dupe(u8, home);
        }
    } else if (environ.getPosix("PKEXEC_UID")) |uid| {
        if (homeFromPasswd(passwd, null, uid)) |home| return allocator.dupe(u8, home);
    }
    return allocator.dupe(u8, fallback);
}

pub fn homeFromPasswd(passwd: []const u8, username: ?[]const u8, uid: ?[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, ':');
        const field_user = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const field_uid = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const home = fields.next() orelse continue;
        if (username) |expected| {
            if (std.mem.eql(u8, field_user, expected)) return home;
        } else if (uid) |expected| {
            if (std.mem.eql(u8, field_uid, expected)) return home;
        }
    }
    return null;
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
    } else if (environ.getPosix("PKEXEC_UID")) |uid| {
        const username = try resolveUsernameForUid(allocator, io, uid);
        defer allocator.free(username);
        try appendOwned(allocator, &argv, &.{ "runuser", "-u", username, "-w", "PATH", "--", command });
    } else try appendOwned(allocator, &argv, &.{command});

    try appendOwned(allocator, &argv, arguments);
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

fn appendOwned(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), values: []const []const u8) !void {
    for (values) |value| try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn makepkgCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    use_chroot: bool,
    chroot_path: []const u8,
    no_check: bool,
) !OwnedCommand {
    if (use_chroot) {
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

    const base = [_][]const u8{ "-f", "-c", "-s", "--noconfirm", "--needed", "--skippgpcheck" };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &base);
    if (no_check) try args.append(allocator, "--nocheck");
    return invokingUserCommand(allocator, io, environ, "makepkg", args.items);
}

pub fn makepkgHistoricalCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    no_check: bool,
) !OwnedCommand {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "--noconfirm");
    if (no_check) try args.append(allocator, "--nocheck");
    return invokingUserCommand(allocator, io, environ, "makepkg", args.items);
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
    const prefix = try std.fmt.allocPrint(allocator, "{s}-", .{package_name});
    defer allocator.free(prefix);
    var has_named_match = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isBuiltPackageFile(entry.name)) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) has_named_match = true;
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ directory_path, entry.name }));
    }
    if (paths.items.len > 1 and !has_named_match) {
        for (paths.items) |path| allocator.free(path);
        paths.clearRetainingCapacity();
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

pub fn cleanBuildArtifacts(io: std.Io, temp_path: []const u8) void {
    for ([_][]const u8{ "src", "pkg" }) |name| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ temp_path, name }) catch continue;
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }
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

test "UID lookup and VCS build commands replicate invoking-user behavior" {
    const passwd = "root:x:0:0::/root:/bin/bash\nzoey:x:1000:1000::/home/zoey:/bin/bash\n";
    try std.testing.expectEqualStrings("zoey", resolveUsernameForUidFromPasswd("1000", passwd));
    try std.testing.expectEqualStrings("55", resolveUsernameForUidFromPasswd("55", passwd));
    try std.testing.expectEqualStrings("/home/zoey", homeFromPasswd(passwd, "zoey", null).?);
    try std.testing.expectEqualStrings("/home/zoey", homeFromPasswd(passwd, null, "1000").?);

    var command = try makepkgCommand(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        false,
        "/var/lib/shelly/chroot",
        true,
    );
    defer command.deinit(std.testing.allocator);
    var found_nocheck = false;
    for (command.argv) |argument| {
        if (std.mem.eql(u8, argument, "--nocheck")) found_nocheck = true;
    }
    try std.testing.expect(found_nocheck);

    var historical = try makepkgHistoricalCommand(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        true,
    );
    defer historical.deinit(std.testing.allocator);
    var found_force = false;
    var found_historical_nocheck = false;
    for (historical.argv) |argument| {
        if (std.mem.eql(u8, argument, "-f")) found_force = true;
        if (std.mem.eql(u8, argument, "--nocheck")) found_historical_nocheck = true;
    }
    try std.testing.expect(!found_force);
    try std.testing.expect(found_historical_nocheck);
}

test "built package selection mirrors split-package and stale-output safeguards" {
    var matching = std.testing.tmpDir(.{});
    defer matching.cleanup();
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-1-1-x86_64.pkg.tar.zst", .data = "" });
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-docs-1-1-any.pkg.tar.zst", .data = "" });
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-1-1-x86_64.pkg.tar.zst.sig", .data = "" });
    const matching_path = try matching.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(matching_path);
    const split_files = try selectBuiltPackageFiles(std.testing.allocator, std.testing.io, matching_path, "demo");
    defer deinitPaths(std.testing.allocator, split_files);
    try std.testing.expectEqual(@as(usize, 2), split_files.len);

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

    var context = operation_api.OperationContext.init(std.testing.allocator, std.testing.io);
    defer context.deinit();
    context.cancel();
    var operation = context.begin(.{ .backend = .aur, .kind = .build, .subject = "cancelled-build" });
    defer operation.finish(.cancelled);

    try std.testing.expectError(error.Cancelled, runStreamingWithEnvironmentOperation(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        &.{ "sh", "-c", "sleep 5" },
        null,
        null,
        .{ .function = Capture.onLine },
        &operation,
    ));
}
