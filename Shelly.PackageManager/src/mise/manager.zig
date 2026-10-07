//! Developer tools managed by mise (https://mise.jdx.dev).
//!
//! Shelly does not link against mise or read its files directly. Every
//! operation runs the user's `mise` executable with an argv (never a shell)
//! from the user's home directory, so results follow the global configuration
//! instead of whichever project directory Shelly happened to start in.
//!
//! mise state belongs to a regular user. Callers must not run these
//! operations as root; the CLI re-launches itself as the invoking user before
//! reaching this module. Because a re-launched process receives a minimal
//! environment, the command environment always appends the standard user
//! installation directory and the mise shims directory to PATH.

const std = @import("std");
const operation_api = @import("operation_context");

pub const Error = error{
    MiseNotInstalled,
    MiseCommandFailed,
    MiseOutputInvalid,
    MiseToolNotInstalled,
    InvalidMiseToolName,
    HomeNotSet,
};

const default_search_path = "/usr/local/sbin:/usr/local/bin:/usr/bin:/bin";
const executable_name = "mise";
const max_command_output = 16 * 1024 * 1024;
const query_timeout_seconds = 300;

/// One active tool version reported by `mise ls --current --json`.
pub const Tool = struct {
    name: []const u8,
    version: []const u8,
    requested_version: ?[]const u8 = null,
    install_path: ?[]const u8 = null,
    installed: bool = false,
    active: bool = false,
    source_type: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
};

/// One tool with a newer version that still satisfies its configured request,
/// as reported by `mise outdated --json`.
pub const OutdatedTool = struct {
    name: []const u8,
    requested: ?[]const u8 = null,
    current: ?[]const u8 = null,
    latest: []const u8,
    bump: ?[]const u8 = null,
    release_url: ?[]const u8 = null,
    source_type: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
};

/// Owned query result. Every string is owned by the list's arena.
pub fn List(comptime T: type) type {
    return struct {
        items: []const T = &.{},
        arena: ?*std.heap.ArenaAllocator = null,

        pub fn deinit(self: *@This()) void {
            if (self.arena) |arena| {
                const child = arena.child_allocator;
                arena.deinit();
                child.destroy(arena);
            }
            self.* = undefined;
        }
    };
}

pub const ToolList = List(Tool);
pub const OutdatedList = List(OutdatedTool);

/// A fully resolved mise invocation.
pub const Command = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    environ_map: *const std.process.Environ.Map,
};

pub const CaptureResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const LineHandler = struct {
    function: *const fn (data: ?*anyopaque, line: []const u8) void,
    data: ?*anyopaque = null,

    fn call(self: LineHandler, line: []const u8) void {
        self.function(self.data, line);
    }
};

/// Process boundary. Tests replace it to observe argv without running mise.
pub const Runner = struct {
    data: ?*anyopaque = null,
    capture: *const fn (
        data: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        command: Command,
    ) anyerror!CaptureResult = captureCommand,
    stream: *const fn (
        data: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        command: Command,
        line_handler: LineHandler,
        operation: ?*const operation_api.Operation,
    ) anyerror!u8 = streamCommand,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    runner: Runner = .{},
    operation_context: ?*operation_api.OperationContext = null,

    pub fn setOperationContext(self: *Manager, context: ?*operation_api.OperationContext) void {
        self.operation_context = context;
    }

    /// Reports whether a mise executable can be found for this environment.
    pub fn isInstalled(self: *const Manager) bool {
        var session = (self.openSession() catch return false) orelse return false;
        session.deinit();
        return true;
    }

    /// Lists the tools active in the user's global context. Returns an empty
    /// list when mise is not installed.
    pub fn listInstalled(self: *const Manager) !ToolList {
        var session = (try self.openSession()) orelse return .{};
        defer session.deinit();
        const stdout = try self.capture(&session, &.{ "ls", "--current", "--json" });
        defer self.allocator.free(stdout);
        return parseInstalled(self.allocator, stdout);
    }

    /// Lists tools with newer versions allowed by their configured requests.
    /// Pinned requests such as `node = "26"` only report newer 26.x releases.
    /// Returns an empty list when mise is not installed.
    pub fn listOutdated(self: *const Manager) !OutdatedList {
        var session = (try self.openSession()) orelse return .{};
        defer session.deinit();
        const stdout = try self.capture(&session, &.{ "outdated", "--json" });
        defer self.allocator.free(stdout);
        return parseOutdated(self.allocator, stdout);
    }

    /// Upgrades the named tools within their configured requests, or every
    /// outdated tool when `tools` is empty. mise output is forwarded as
    /// operation status lines.
    pub fn upgrade(self: *const Manager, tools: []const []const u8) !void {
        for (tools) |tool| try validateToolName(tool);
        var session = (try self.openSession()) orelse return Error.MiseNotInstalled;
        defer session.deinit();

        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(self.allocator);
        try arguments.appendSlice(self.allocator, &.{ "upgrade", "--yes" });
        try arguments.appendSlice(self.allocator, tools);

        var operation = self.beginOperation(.update, if (tools.len == 1) tools[0] else null);
        defer if (operation) |*active| active.finish(.success);
        errdefer if (operation) |*active| active.finish(.failed);
        try self.stream(&session, arguments.items, if (operation) |*active| active else null);
    }

    /// Removes a tool request from the configuration file that declared it,
    /// letting mise prune installs that are no longer referenced. Requests
    /// without a configuration file fall back to the global configuration.
    pub fn remove(self: *const Manager, tool: []const u8) !void {
        try validateToolName(tool);
        var session = (try self.openSession()) orelse return Error.MiseNotInstalled;
        defer session.deinit();

        const stdout = try self.capture(&session, &.{ "ls", "--current", "--json" });
        defer self.allocator.free(stdout);
        var installed = try parseInstalled(self.allocator, stdout);
        defer installed.deinit();

        var sources: std.ArrayList(?[]const u8) = .empty;
        defer sources.deinit(self.allocator);
        for (installed.items) |item| {
            if (!std.mem.eql(u8, item.name, tool)) continue;
            const source = if (item.source_path) |path| (if (path.len == 0) null else path) else null;
            const seen = for (sources.items) |existing| {
                if (optionalEql(existing, source)) break true;
            } else false;
            if (!seen) try sources.append(self.allocator, source);
        }
        if (sources.items.len == 0) return Error.MiseToolNotInstalled;

        var operation = self.beginOperation(.remove, tool);
        defer if (operation) |*active| active.finish(.success);
        errdefer if (operation) |*active| active.finish(.failed);
        for (sources.items) |source| {
            const arguments = try unuseArguments(self.allocator, tool, source);
            defer self.allocator.free(arguments);
            try self.stream(&session, arguments, if (operation) |*active| active else null);
        }
    }

    const Session = struct {
        allocator: std.mem.Allocator,
        environment: std.process.Environ.Map,
        executable: []u8,
        home: []u8,

        fn deinit(self: *Session) void {
            self.allocator.free(self.executable);
            self.allocator.free(self.home);
            self.environment.deinit();
            self.* = undefined;
        }
    };

    fn openSession(self: *const Manager) !?Session {
        var environment = try commandEnvironment(self.allocator, self.environ);
        errdefer environment.deinit();
        const executable = (try locateExecutable(
            self.allocator,
            self.io,
            environment.get("PATH") orelse default_search_path,
        )) orelse {
            environment.deinit();
            return null;
        };
        errdefer self.allocator.free(executable);
        const home = try self.allocator.dupe(u8, environment.get("HOME") orelse return Error.HomeNotSet);
        return .{
            .allocator = self.allocator,
            .environment = environment,
            .executable = executable,
            .home = home,
        };
    }

    fn capture(self: *const Manager, session: *Session, arguments: []const []const u8) ![]u8 {
        const argv = try commandArgv(self.allocator, session.executable, arguments);
        defer self.allocator.free(argv);
        var result = try self.runner.capture(self.runner.data, self.allocator, self.io, .{
            .argv = argv,
            .cwd = session.home,
            .environ_map = &session.environment,
        });
        if (result.exit_code != 0) {
            const details = std.mem.trim(u8, result.stderr, " \t\r\n");
            if (details.len != 0) std.log.warn("mise {s} failed: {s}", .{ arguments[0], details });
            result.deinit(self.allocator);
            return Error.MiseCommandFailed;
        }
        self.allocator.free(result.stderr);
        return result.stdout;
    }

    fn stream(
        self: *const Manager,
        session: *Session,
        arguments: []const []const u8,
        operation: ?*const operation_api.Operation,
    ) !void {
        const argv = try commandArgv(self.allocator, session.executable, arguments);
        defer self.allocator.free(argv);
        const Forward = struct {
            fn line(data: ?*anyopaque, text: []const u8) void {
                const active: *const operation_api.Operation = @ptrCast(@alignCast(data orelse return));
                active.status(.information, text, "mise.output", null);
            }
        };
        const exit_code = try self.runner.stream(
            self.runner.data,
            self.allocator,
            self.io,
            .{ .argv = argv, .cwd = session.home, .environ_map = &session.environment },
            .{ .function = Forward.line, .data = if (operation) |active| @constCast(active) else null },
            operation,
        );
        if (exit_code != 0) return Error.MiseCommandFailed;
    }

    fn beginOperation(
        self: *const Manager,
        kind: operation_api.OperationKind,
        subject: ?[]const u8,
    ) ?operation_api.Operation {
        const context = self.operation_context orelse return null;
        return context.begin(.{ .backend = .mise, .kind = kind, .subject = subject });
    }
};

/// Builds the child environment: the caller's environment plus a PATH that
/// always reaches `~/.local/bin` and the mise shims directory.
pub fn commandEnvironment(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
) !std.process.Environ.Map {
    var environment = try environ.createMap(allocator);
    errdefer environment.deinit();
    const home = environment.get("HOME") orelse return Error.HomeNotSet;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return Error.HomeNotSet;

    const user_bin = try std.fs.path.join(allocator, &.{ home, ".local", "bin" });
    defer allocator.free(user_bin);
    const data_directory = try dataDirectory(allocator, &environment);
    defer allocator.free(data_directory);
    const shims = try std.fs.path.join(allocator, &.{ data_directory, "shims" });
    defer allocator.free(shims);
    const path = try searchPath(
        allocator,
        environment.get("PATH") orelse default_search_path,
        &.{ user_bin, shims },
    );
    defer allocator.free(path);
    try environment.put("PATH", path);
    return environment;
}

/// Resolves mise's data directory the same way mise does.
pub fn dataDirectory(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    if (environment.get("MISE_DATA_DIR")) |configured| {
        if (configured.len != 0) return allocator.dupe(u8, configured);
    }
    if (environment.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len != 0) return std.fs.path.join(allocator, &.{ data_home, "mise" });
    }
    const home = environment.get("HOME") orelse return Error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "mise" });
}

/// Appends each missing directory to a colon-separated search path.
pub fn searchPath(
    allocator: std.mem.Allocator,
    existing: []const u8,
    additions: []const []const u8,
) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, existing);
    for (additions) |addition| {
        if (pathContains(existing, addition)) continue;
        if (result.items.len != 0) try result.append(allocator, ':');
        try result.appendSlice(allocator, addition);
    }
    return result.toOwnedSlice(allocator);
}

fn pathContains(path: []const u8, directory: []const u8) bool {
    var entries = std.mem.splitScalar(u8, path, ':');
    while (entries.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, entry, "/"), std.mem.trimEnd(u8, directory, "/"))) return true;
    }
    return false;
}

/// Finds the first executable `mise` in an absolute PATH entry. Relative
/// entries are ignored so the working directory cannot select the executable.
pub fn locateExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?[]u8 {
    var entries = std.mem.splitScalar(u8, path, ':');
    while (entries.next()) |entry| {
        if (entry.len == 0 or !std.fs.path.isAbsolute(entry)) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, executable_name });
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        if (stat.kind != .file) {
            allocator.free(candidate);
            continue;
        }
        std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
            allocator.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Tool names are passed to mise as positional arguments, so a leading dash
/// would be parsed as an option.
pub fn validateToolName(name: []const u8) !void {
    if (name.len == 0 or name[0] == '-') return Error.InvalidMiseToolName;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return Error.InvalidMiseToolName;
    }
}

/// `mise unuse` for one declaring configuration file, or the global
/// configuration when mise did not report one.
pub fn unuseArguments(
    allocator: std.mem.Allocator,
    tool: []const u8,
    source_path: ?[]const u8,
) ![]const []const u8 {
    if (source_path) |path|
        return allocator.dupe([]const u8, &.{ "unuse", "--path", path, tool });
    return allocator.dupe([]const u8, &.{ "unuse", "--global", tool });
}

fn commandArgv(
    allocator: std.mem.Allocator,
    executable: []const u8,
    arguments: []const []const u8,
) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, arguments.len + 1);
    argv[0] = executable;
    @memcpy(argv[1..], arguments);
    return argv;
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// Parses `mise ls --current --json`: an object keyed by tool name whose
/// values are arrays of version records. Unknown fields are ignored and
/// missing optional fields default to null/false.
pub fn parseInstalled(allocator: std.mem.Allocator, json: []const u8) !ToolList {
    const arena = try createArena(allocator);
    errdefer destroyArena(allocator, arena);
    const scratch = arena.allocator();
    const root = (try parseRoot(scratch, json)) orelse
        return .{ .items = &.{}, .arena = arena };

    var tools: std.ArrayList(Tool) = .empty;
    var entries = root.iterator();
    while (entries.next()) |entry| {
        const versions = switch (entry.value_ptr.*) {
            .array => |array| array.items,
            else => return Error.MiseOutputInvalid,
        };
        for (versions) |version| {
            const record = switch (version) {
                .object => |object| object,
                else => return Error.MiseOutputInvalid,
            };
            const source = objectField(record, "source");
            try tools.append(scratch, .{
                .name = entry.key_ptr.*,
                .version = stringField(record, "version") orelse "",
                .requested_version = stringField(record, "requested_version"),
                .install_path = stringField(record, "install_path"),
                .installed = boolField(record, "installed") orelse false,
                .active = boolField(record, "active") orelse false,
                .source_type = if (source) |object| stringField(object, "type") else null,
                .source_path = if (source) |object| stringField(object, "path") else null,
            });
        }
    }
    const items = try tools.toOwnedSlice(scratch);
    std.mem.sort(Tool, items, {}, struct {
        fn lessThan(_: void, left: Tool, right: Tool) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return .{ .items = items, .arena = arena };
}

/// Parses `mise outdated --json`: an object keyed by tool name. Entries
/// without a latest version are skipped because there is nothing to offer.
pub fn parseOutdated(allocator: std.mem.Allocator, json: []const u8) !OutdatedList {
    const arena = try createArena(allocator);
    errdefer destroyArena(allocator, arena);
    const scratch = arena.allocator();
    const root = (try parseRoot(scratch, json)) orelse
        return .{ .items = &.{}, .arena = arena };

    var tools: std.ArrayList(OutdatedTool) = .empty;
    var entries = root.iterator();
    while (entries.next()) |entry| {
        const record = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return Error.MiseOutputInvalid,
        };
        const latest = stringField(record, "latest") orelse continue;
        if (latest.len == 0) continue;
        const source = objectField(record, "source");
        try tools.append(scratch, .{
            .name = stringField(record, "name") orelse entry.key_ptr.*,
            .requested = stringField(record, "requested"),
            .current = stringField(record, "current"),
            .latest = latest,
            .bump = stringField(record, "bump"),
            .release_url = stringField(record, "release_url"),
            .source_type = if (source) |object| stringField(object, "type") else null,
            .source_path = if (source) |object| stringField(object, "path") else null,
        });
    }
    const items = try tools.toOwnedSlice(scratch);
    std.mem.sort(OutdatedTool, items, {}, struct {
        fn lessThan(_: void, left: OutdatedTool, right: OutdatedTool) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return .{ .items = items, .arena = arena };
}

fn parseRoot(allocator: std.mem.Allocator, json: []const u8) !?std.json.ObjectMap {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.MiseOutputInvalid,
    };
    return switch (value) {
        .object => |object| object,
        else => Error.MiseOutputInvalid,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    return switch (object.get(name) orelse return null) {
        .bool => |value| value,
        else => null,
    };
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    return switch (object.get(name) orelse return null) {
        .object => |value| value,
        else => null,
    };
}

fn createArena(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    allocator.destroy(arena);
}

fn captureCommand(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    command: Command,
) anyerror!CaptureResult {
    const result = try std.process.run(allocator, io, .{
        .argv = command.argv,
        .cwd = if (command.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = command.environ_map,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(query_timeout_seconds) } },
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

fn streamCommand(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    command: Command,
    line_handler: LineHandler,
    operation: ?*const operation_api.Operation,
) anyerror!u8 {
    var child = try std.process.spawn(io, .{
        .argv = command.argv,
        .cwd = if (command.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = command.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    // Upgrades have no deadline; poll so a cancelled operation stops mise.
    const poll: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(250) } };
    while (true) {
        multi_reader.fill(4096, poll) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (operation) |active| if (active.isCancelled()) return error.Cancelled;
                continue;
            },
            else => |other| return other,
        };
        if (operation) |active| if (active.isCancelled()) return error.Cancelled;
        drainLines(multi_reader.reader(0), false, line_handler);
        drainLines(multi_reader.reader(1), false, line_handler);
    }
    try multi_reader.checkAnyError();
    drainLines(multi_reader.reader(0), true, line_handler);
    drainLines(multi_reader.reader(1), true, line_handler);
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 255,
    };
}

fn drainLines(reader: *std.Io.Reader, flush_tail: bool, line_handler: LineHandler) void {
    while (std.mem.indexOfAny(u8, reader.buffered(), "\r\n")) |line_end| {
        const line = reader.buffered()[0..line_end];
        if (std.mem.trim(u8, line, " \t").len != 0) line_handler.call(line);
        reader.toss(line_end + 1);
    }
    if (flush_tail and reader.bufferedLen() != 0) {
        const length = reader.bufferedLen();
        const line = std.mem.trim(u8, reader.buffered(), " \t\r");
        if (line.len != 0) line_handler.call(line);
        reader.toss(length);
    }
}

fn testEnviron(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    for (pairs) |pair| try environment.put(pair[0], pair[1]);
    return .{ .block = try environment.createPosixBlock(allocator, .{}) };
}

const installed_fixture =
    \\{
    \\  "node": [
    \\    {"version": "26.8.1", "requested_version": "26", "install_path": "/home/u/.local/share/mise/installs/node/26.8.1",
    \\     "source": {"type": "mise.toml", "path": "/home/u/.config/mise/config.toml"}, "installed": true, "active": true}
    \\  ],
    \\  "npm:playwright": [
    \\    {"version": "1.63.0", "requested_version": "latest", "symlinked_to": "/elsewhere", "future_field": {"x": 1},
    \\     "source": {"type": "mise.toml", "path": "/home/u/project/mise.toml"}, "installed": true, "active": true},
    \\    {"version": "1.60.0"}
    \\  ],
    \\  "cursor-agent": [
    \\    {"version": "2026.09.18-9a7762b", "installed": false, "source": {"type": "environment"}}
    \\  ]
    \\}
;

test "mise installed list parses records, sorts names, and tolerates unknown or missing fields" {
    var list = try parseInstalled(std.testing.allocator, installed_fixture);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("cursor-agent", list.items[0].name);
    try std.testing.expect(!list.items[0].installed);
    try std.testing.expectEqualStrings("environment", list.items[0].source_type.?);
    try std.testing.expectEqual(@as(?[]const u8, null), list.items[0].source_path);
    try std.testing.expectEqualStrings("node", list.items[1].name);
    try std.testing.expectEqualStrings("26.8.1", list.items[1].version);
    try std.testing.expectEqualStrings("26", list.items[1].requested_version.?);
    try std.testing.expect(list.items[1].active);
    try std.testing.expectEqualStrings("/home/u/.config/mise/config.toml", list.items[1].source_path.?);
    try std.testing.expectEqualStrings("npm:playwright", list.items[2].name);
    try std.testing.expectEqualStrings("/home/u/project/mise.toml", list.items[2].source_path.?);
    try std.testing.expectEqualStrings("1.60.0", list.items[3].version);
    try std.testing.expectEqual(@as(?[]const u8, null), list.items[3].requested_version);
    try std.testing.expect(!list.items[3].active);
}

test "mise outdated list keeps requests and skips entries without a latest version" {
    const fixture =
        \\{"node": {"name": "node", "requested": "26", "current": "26.8.1", "bump": null, "latest": "26.10.0",
        \\  "source": {"type": "mise.toml", "path": "/home/u/.config/mise/config.toml"}},
        \\ "claude": {"requested": "latest", "current": "2.1.280", "latest": "2.1.291",
        \\  "release_url": "https://example.test/v2.1.291", "unexpected": [1, 2]},
        \\ "broken": {"name": "broken", "current": "1.0"}}
    ;
    var list = try parseOutdated(std.testing.allocator, fixture);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("claude", list.items[0].name);
    try std.testing.expectEqualStrings("2.1.291", list.items[0].latest);
    try std.testing.expectEqualStrings("https://example.test/v2.1.291", list.items[0].release_url.?);
    try std.testing.expectEqual(@as(?[]const u8, null), list.items[0].source_path);
    try std.testing.expectEqualStrings("node", list.items[1].name);
    try std.testing.expectEqualStrings("26", list.items[1].requested.?);
    try std.testing.expectEqualStrings("26.8.1", list.items[1].current.?);
    try std.testing.expectEqual(@as(?[]const u8, null), list.items[1].bump);
}

test "mise output parsing accepts empty documents and rejects malformed ones" {
    var empty = try parseInstalled(std.testing.allocator, "{}\n");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    var blank = try parseOutdated(std.testing.allocator, "  \n");
    defer blank.deinit();
    try std.testing.expectEqual(@as(usize, 0), blank.items.len);
    try std.testing.expectError(Error.MiseOutputInvalid, parseInstalled(std.testing.allocator, "[]"));
    try std.testing.expectError(Error.MiseOutputInvalid, parseInstalled(std.testing.allocator, "{\"node\": {}}"));
    try std.testing.expectError(Error.MiseOutputInvalid, parseOutdated(std.testing.allocator, "not json"));
}

test "mise command environment appends user bin and shims without duplicating PATH entries" {
    const allocator = std.testing.allocator;
    var environ = try testEnviron(allocator, &.{
        .{ "HOME", "/home/u" },
        .{ "PATH", "/usr/bin:/home/u/.local/bin" },
        .{ "XDG_DATA_HOME", "/home/u/.local/share" },
    });
    defer environ.block.deinit(allocator);
    var environment = try commandEnvironment(allocator, environ);
    defer environment.deinit();
    try std.testing.expectEqualStrings(
        "/usr/bin:/home/u/.local/bin:/home/u/.local/share/mise/shims",
        environment.get("PATH").?,
    );

    var minimal = try testEnviron(allocator, &.{ .{ "HOME", "/home/u" }, .{ "MISE_DATA_DIR", "/data/mise" } });
    defer minimal.block.deinit(allocator);
    var minimal_environment = try commandEnvironment(allocator, minimal);
    defer minimal_environment.deinit();
    try std.testing.expectEqualStrings(
        default_search_path ++ ":/home/u/.local/bin:/data/mise/shims",
        minimal_environment.get("PATH").?,
    );

    var homeless = try testEnviron(allocator, &.{.{ "PATH", "/usr/bin" }});
    defer homeless.block.deinit(allocator);
    try std.testing.expectError(Error.HomeNotSet, commandEnvironment(allocator, homeless));
}

test "mise tool names cannot become options or control sequences" {
    try validateToolName("node");
    try validateToolName("npm:@xai-official/grok");
    try std.testing.expectError(Error.InvalidMiseToolName, validateToolName(""));
    try std.testing.expectError(Error.InvalidMiseToolName, validateToolName("--global"));
    try std.testing.expectError(Error.InvalidMiseToolName, validateToolName("node\nrm"));
}

test "mise unuse targets the declaring file or falls back to the global config" {
    const allocator = std.testing.allocator;
    const with_path = try unuseArguments(allocator, "node", "/home/u/.config/mise/config.toml");
    defer allocator.free(with_path);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "unuse", "--path", "/home/u/.config/mise/config.toml", "node" },
        with_path,
    );
    const global = try unuseArguments(allocator, "node", null);
    defer allocator.free(global);
    try std.testing.expectEqualSlices([]const u8, &.{ "unuse", "--global", "node" }, global);
}

const FakeRunner = struct {
    allocator: std.mem.Allocator,
    installed_json: []const u8 = "{}",
    stream_exit_code: u8 = 0,
    captured: std.ArrayList([]const u8) = .empty,
    streamed: std.ArrayList([]const u8) = .empty,
    cwd: ?[]const u8 = null,

    fn deinit(self: *FakeRunner) void {
        for (self.captured.items) |line| self.allocator.free(line);
        for (self.streamed.items) |line| self.allocator.free(line);
        self.captured.deinit(self.allocator);
        self.streamed.deinit(self.allocator);
        if (self.cwd) |cwd| self.allocator.free(cwd);
    }

    fn runner(self: *FakeRunner) Runner {
        return .{ .data = self, .capture = capture, .stream = stream };
    }

    fn joined(self: *FakeRunner, argv: []const []const u8) ![]const u8 {
        // Drop the resolved executable so assertions stay path independent.
        return std.mem.join(self.allocator, " ", argv[1..]);
    }

    fn capture(data: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, command: Command) anyerror!CaptureResult {
        const self: *FakeRunner = @ptrCast(@alignCast(data.?));
        try self.captured.append(self.allocator, try self.joined(command.argv));
        if (self.cwd == null) self.cwd = try self.allocator.dupe(u8, command.cwd.?);
        return .{
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, self.installed_json),
            .stderr = try allocator.dupe(u8, ""),
        };
    }

    fn stream(
        data: ?*anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        command: Command,
        line_handler: LineHandler,
        _: ?*const operation_api.Operation,
    ) anyerror!u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(data.?));
        try self.streamed.append(self.allocator, try self.joined(command.argv));
        line_handler.call("mise node@26.10.0 installed");
        return self.stream_exit_code;
    }
};

fn testManagerRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bin/mise",
        .data = "#!/bin/sh\nexit 0\n",
        .flags = .{ .permissions = .executable_file },
    });
    return buffer[0..try tmp.dir.realPath(std.testing.io, buffer)];
}

test "mise manager runs upgrade and unuse with argv from the home directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try testManagerRoot(&tmp, &path_buffer);
    const bin = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin);
    var environ = try testEnviron(allocator, &.{ .{ "HOME", root }, .{ "PATH", bin } });
    defer environ.block.deinit(allocator);

    var fake: FakeRunner = .{
        .allocator = allocator,
        .installed_json =
        \\{"node": [{"version": "26.8.1", "source": {"type": "mise.toml", "path": "/cfg/a.toml"}},
        \\          {"version": "24.1.0", "source": {"type": "mise.toml", "path": "/cfg/a.toml"}}],
        \\ "gh": [{"version": "2.100.0"}]}
        ,
    };
    defer fake.deinit();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(allocator, threaded.io());
    defer context.deinit();
    const Capture = struct {
        statuses: usize = 0,
        saw_backend: bool = false,

        fn receive(data: ?*anyopaque, event: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (event) {
                .status => |status| {
                    self.statuses += 1;
                    self.saw_backend = status.envelope.backend == .mise;
                },
                else => {},
            }
        }
    };
    var observed: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.receive, .data = &observed });

    var manager = Manager{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = environ,
        .runner = fake.runner(),
    };
    manager.setOperationContext(&context);
    try std.testing.expect(manager.isInstalled());

    try manager.upgrade(&.{});
    try manager.upgrade(&.{ "node", "npm:playwright" });
    try manager.remove("node");
    try manager.remove("gh");
    try std.testing.expectError(Error.MiseToolNotInstalled, manager.remove("python"));
    try std.testing.expectError(Error.InvalidMiseToolName, manager.upgrade(&.{"--bump"}));

    try std.testing.expectEqual(@as(usize, 4), fake.streamed.items.len);
    try std.testing.expectEqualStrings("upgrade --yes", fake.streamed.items[0]);
    try std.testing.expectEqualStrings("upgrade --yes node npm:playwright", fake.streamed.items[1]);
    try std.testing.expectEqualStrings("unuse --path /cfg/a.toml node", fake.streamed.items[2]);
    try std.testing.expectEqualStrings("unuse --global gh", fake.streamed.items[3]);
    try std.testing.expectEqualStrings("ls --current --json", fake.captured.items[0]);
    try std.testing.expectEqualStrings(root, fake.cwd.?);
    try std.testing.expectEqual(@as(usize, 4), observed.statuses);
    try std.testing.expect(observed.saw_backend);

    fake.stream_exit_code = 1;
    try std.testing.expectError(Error.MiseCommandFailed, manager.upgrade(&.{"node"}));
}

test "mise manager reports an absent executable as empty lists or a clear error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    var environ = try testEnviron(allocator, &.{ .{ "HOME", root }, .{ "PATH", root } });
    defer environ.block.deinit(allocator);
    var fake: FakeRunner = .{ .allocator = allocator };
    defer fake.deinit();
    const manager = Manager{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = environ,
        .runner = fake.runner(),
    };
    try std.testing.expect(!manager.isInstalled());
    var installed = try manager.listInstalled();
    defer installed.deinit();
    try std.testing.expectEqual(@as(usize, 0), installed.items.len);
    var outdated = try manager.listOutdated();
    defer outdated.deinit();
    try std.testing.expectEqual(@as(usize, 0), outdated.items.len);
    try std.testing.expectError(Error.MiseNotInstalled, manager.upgrade(&.{}));
    try std.testing.expectError(Error.MiseNotInstalled, manager.remove("node"));
    try std.testing.expectEqual(@as(usize, 0), fake.captured.items.len);
}

test "mise manager executes the resolved binary and streams its output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    // A stand-in executable that answers the queries Shelly issues and
    // records each invocation, proving argv reaches mise unchanged.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bin/mise",
        .data =
        \\#!/bin/sh
        \\printf '%s\n' "$*" >> "$HOME/calls"
        \\case "$1" in
        \\  ls) printf '{"node":[{"version":"26.8.1","source":{"type":"mise.toml","path":"%s/cfg.toml"}}]}\n' "$HOME" ;;
        \\  outdated) printf '{"node":{"name":"node","requested":"26","current":"26.8.1","latest":"26.10.0"}}' ;;
        \\  upgrade) echo "installing node@26.10.0"; echo "warning on stderr" >&2; printf 'tail' ;;
        \\  unuse) exit 3 ;;
        \\esac
        \\
        ,
        .flags = .{ .permissions = .executable_file },
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    const bin = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin);
    const search = try std.mem.concat(allocator, u8, &.{ bin, ":/usr/bin:/bin" });
    defer allocator.free(search);
    var environ = try testEnviron(allocator, &.{ .{ "HOME", root }, .{ "PATH", search } });
    defer environ.block.deinit(allocator);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var context = operation_api.OperationContext.init(allocator, threaded.io());
    defer context.deinit();
    const Lines = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayList(u8) = .empty,

        fn receive(data: ?*anyopaque, event: operation_api.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (event) {
                .status => |status| {
                    self.text.appendSlice(self.allocator, status.message) catch {};
                    self.text.append(self.allocator, '|') catch {};
                },
                else => {},
            }
        }
    };
    var lines: Lines = .{ .allocator = allocator };
    defer lines.text.deinit(allocator);
    _ = try context.subscribe(.{ .function = Lines.receive, .data = &lines });

    var manager = Manager{ .allocator = allocator, .io = std.testing.io, .environ = environ };
    manager.setOperationContext(&context);

    var installed = try manager.listInstalled();
    defer installed.deinit();
    try std.testing.expectEqual(@as(usize, 1), installed.items.len);
    try std.testing.expectEqualStrings("26.8.1", installed.items[0].version);
    var outdated = try manager.listOutdated();
    defer outdated.deinit();
    try std.testing.expectEqualStrings("26.10.0", outdated.items[0].latest);

    try manager.upgrade(&.{"node"});
    try std.testing.expect(std.mem.indexOf(u8, lines.text.items, "installing node@26.10.0|") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.text.items, "warning on stderr|") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.text.items, "tail|") != null);
    try std.testing.expectError(Error.MiseCommandFailed, manager.remove("node"));

    const calls = try tmp.dir.readFileAlloc(std.testing.io, "calls", allocator, .limited(4096));
    defer allocator.free(calls);
    const expected_unuse = try std.fmt.allocPrint(allocator, "unuse --path {s}/cfg.toml node\n", .{root});
    defer allocator.free(expected_unuse);
    const expected = try std.mem.concat(allocator, u8, &.{
        "ls --current --json\noutdated --json\nupgrade --yes node\nls --current --json\n",
        expected_unuse,
    });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, calls);
}
