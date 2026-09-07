const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const colors = @import("../output/colors.zig");
const table = @import("../output/table.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");

const flatpak_command_path = "shelly run flatpak";
const appimage_command_path = "shelly run appimage";

const Backend = enum {
    flatpak,
    appimage,
};

const RunError = error{
    AmbiguousAppImage,
    AppImageNotFound,
    AppImageProcessUnavailable,
};

const Real = struct {
    fn call(
        _: Real,
        context: *runtime.RuntimeContext,
        backend: Backend,
        kill: bool,
        target: []const u8,
    ) !bool {
        return runReal(context, backend, kill, target);
    }
};

const RunningItem = struct {
    instance_id: []const u8,
    application_id: []const u8,
    arch: []const u8,
    branch: []const u8,
    pid: i32,
    child_pid: i32,
};

const RunningResult = struct {
    items: []const RunningItem,
    arena: ?*std.heap.ArenaAllocator = null,

    fn deinit(self: *RunningResult, allocator: std.mem.Allocator) void {
        const arena = self.arena orelse return;
        arena.deinit();
        allocator.destroy(arena);
        self.* = undefined;
    }
};

const RunningLister = struct {
    fn list(_: @This(), context: *runtime.RuntimeContext) !RunningResult {
        return listRunningReal(context);
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    const backend = backendForPath(invocation.command.path) orelse return null;
    if (backend == .flatpak and listRequested(invocation))
        return try listRunningWith(context, invocation, RunningLister{});
    if (invocation.positionals.len == 0)
        return try reportRunValidationFailure(context, invocation, "A package is required unless listing running Flatpaks.");
    return try executeWithRunner(context, invocation, backend, Real{});
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    runner: anytype,
) anyerror!u8 {
    if (invocation.positionals.len == 0)
        return try reportRunValidationFailure(context, invocation, "A package is required unless listing running Flatpaks.");
    const kill = optionEnabled(invocation, "--kill");
    const target = invocation.positionals[0];
    try writeOpening(context, invocation, backend, kill, target);
    try flush(context);

    const succeeded = runner.call(context, backend, kill, target) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "Unable to {s} {s}: {t}",
            .{ if (kill) "stop" else "launch", backendName(backend), err },
        );
        defer context.allocator.free(message);
        if (invocation.globals.ui_mode)
            try output.writeErrorFrame(context, message)
        else
            try output.writeFailure(context, message);
        try writeCompletion(context, invocation, backend, kill, false);
        try flush(context);
        return 1;
    };

    try writeCompletion(context, invocation, backend, kill, succeeded);
    try flush(context);
    return if (succeeded) 0 else 1;
}

fn listRunningWith(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    lister: anytype,
) anyerror!u8 {
    if (optionEnabled(invocation, "--kill"))
        return try reportRunValidationFailure(context, invocation, "--list and --kill cannot be used together.");
    if (optionEnabled(invocation, "--list") and invocation.positionals.len != 0)
        return try reportRunValidationFailure(context, invocation, "--list does not accept a package.");

    var result = lister.list(context) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Unable to list running Flatpaks: {t}", .{err});
        defer context.allocator.free(message);
        if (invocation.globals.ui_mode)
            try output.writeErrorFrame(context, message)
        else
            try output.writeFailure(context, message);
        try flush(context);
        return 1;
    };
    defer result.deinit(context.allocator);

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeRunningJson(&payload.writer, result.items);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (invocation.globals.json) {
        try writeRunningJson(context.stdout, result.items);
        try context.stdout.writeByte('\n');
    } else {
        try writeRunningPlain(context, result.items);
    }
    try flush(context);
    return 0;
}

fn listRunningReal(context: *runtime.RuntimeContext) !RunningResult {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    const native_items = try manager.get_running_instances_flatpak();
    defer Zigalpm.flatpak.RunningInstance.deinitSlice(context.allocator, native_items);

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    errdefer context.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const items = try allocator.alloc(RunningItem, native_items.len);
    for (native_items, items) |native, *item| item.* = .{
        .instance_id = try allocator.dupe(u8, native.instance_id),
        .application_id = try allocator.dupe(u8, native.application_id),
        .arch = try allocator.dupe(u8, native.arch),
        .branch = try allocator.dupe(u8, native.branch),
        .pid = native.pid,
        .child_pid = native.child_pid,
    };
    return .{ .items = items, .arena = arena };
}

fn writeRunningJson(writer: *std.Io.Writer, items: []const RunningItem) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (items) |item| {
        try json.beginObject();
        try json.objectField("Application");
        try json.write(item.application_id);
        try json.objectField("Instance");
        try json.write(item.instance_id);
        try json.objectField("Pid");
        try json.write(item.pid);
        try json.objectField("ChildPid");
        try json.write(item.child_pid);
        try json.objectField("Arch");
        try json.write(item.arch);
        try json.objectField("Branch");
        try json.write(item.branch);
        try json.endObject();
    }
    try json.endArray();
}

fn writeRunningPlain(context: *runtime.RuntimeContext, items: []const RunningItem) !void {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rows = try allocator.alloc([]const []const u8, items.len);
    for (items, rows) |item, *cells| cells.* = &.{
        item.application_id,
        item.instance_id,
        try std.fmt.allocPrint(allocator, "{d}", .{item.pid}),
        try std.fmt.allocPrint(allocator, "{d}", .{item.child_pid}),
        item.arch,
        item.branch,
    };
    try table.write(
        context,
        &.{ "Application", "Instance", "PID", "Child PID", "Arch", "Branch" },
        rows,
    );
    try context.stdout.print("Total: {d} running Flatpak{s}\n", .{ items.len, if (items.len == 1) "" else "s" });
}

fn listRequested(invocation: *const parser.Invocation) bool {
    return optionEnabled(invocation, "--list") or
        (invocation.positionals.len == 1 and std.ascii.eqlIgnoreCase(invocation.positionals[0], "list"));
}

fn reportRunValidationFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try output.writeFailure(context, message);
    try flush(context);
    return 1;
}

fn runReal(
    context: *runtime.RuntimeContext,
    backend: Backend,
    kill: bool,
    target: []const u8,
) !bool {
    return switch (backend) {
        .flatpak => runFlatpak(context, target, kill),
        .appimage => runAppImage(context, target, kill),
    };
}

fn runFlatpak(context: *runtime.RuntimeContext, target: []const u8, kill: bool) !bool {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    if (!kill) {
        const target_z = try context.allocator.dupeZ(u8, target);
        defer context.allocator.free(target_z);
        return manager.launch_flatpak(target_z);
    }

    var application = (try manager.find_installed_flatpak(target)) orelse return false;
    defer application.deinit(context.allocator);
    return manager.kill_flatpak(application.id);
}

fn runAppImage(context: *runtime.RuntimeContext, query: []const u8, kill: bool) !bool {
    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const fallback_directory = try xdg.binHome(context);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse fallback_directory;
    const search_paths: []const []const u8 = if (std.mem.eql(u8, install_directory, fallback_directory))
        &.{install_directory}
    else
        &.{ install_directory, fallback_directory };
    const target = try resolveAppImage(context.allocator, context.io, query, search_paths);
    defer context.allocator.free(target);

    return if (kill)
        killAppImage(context, target)
    else
        launchAppImage(context, target);
}

fn launchAppImage(context: *runtime.RuntimeContext, target: []const u8) !bool {
    const config_home = try xdg.configHome(context);
    defer context.allocator.free(config_home);
    const database = try std.fs.path.join(context.allocator, &.{ config_home, "shelly", "appimage-metadata-v2.db" });
    defer context.allocator.free(database);
    var manager = Zigalpm.AppImageManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = std.fs.path.dirname(target) orelse ".",
        .local_db_path = database,
    };
    defer manager.deinit();
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    var environment = try context.environ.createMap(context.allocator);
    defer environment.deinit();
    const resolved_target = try std.Io.Dir.cwd().realPathFileAlloc(context.io, target, context.allocator);
    defer context.allocator.free(resolved_target);
    for (apps) |app| {
        const resolved_app = std.Io.Dir.cwd().realPathFileAlloc(context.io, app.path, context.allocator) catch continue;
        defer context.allocator.free(resolved_app);
        if (std.mem.eql(u8, resolved_target, resolved_app)) {
            try Zigalpm.appimage.environment.overlay(&environment, app.environment_variables);
            break;
        }
    }
    var child = try std.process.spawn(context.io, .{
        .argv = &.{target},
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Give the AppImage and any processes it creates a group that can be
        // stopped as one unit by a later `run appimage --kill` invocation.
        .pgid = 0,
    });
    errdefer child.kill(context.io);

    const pid: std.posix.pid_t = child.id orelse return RunError.AppImageProcessUnavailable;
    const start_time = try processStartTime(context, pid);
    try writeTrackedProcess(context, target, pid, start_time);

    // Intentionally do not wait: the CLI is a launcher. Once Shelly exits the
    // child is adopted and reaped by the user's process supervisor/init.
    return true;
}

fn killAppImage(context: *runtime.RuntimeContext, target: []const u8) !bool {
    const state_path = try processStatePath(context, target);
    defer context.allocator.free(state_path);

    if (readTrackedProcess(context, state_path)) |tracked| {
        const current_start = processStartTime(context, tracked.pid) catch null;
        if (current_start != null and current_start.? == tracked.start_time) {
            std.posix.kill(-tracked.pid, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => return err,
            };
            std.Io.Dir.cwd().deleteFile(context.io, state_path) catch {};
            return true;
        }
        std.Io.Dir.cwd().deleteFile(context.io, state_path) catch {};
    } else |_| {}

    // Also support AppImages started outside Shelly. The AppImage runtime
    // exports APPIMAGE=<original path> to its child process, which gives us an
    // exact match without relying on broad process-name searches.
    return killDiscoveredAppImages(context, target);
}

const TrackedProcess = struct {
    pid: std.posix.pid_t,
    start_time: u64,
};

fn writeTrackedProcess(
    context: *runtime.RuntimeContext,
    target: []const u8,
    pid: std.posix.pid_t,
    start_time: u64,
) !void {
    const state_path = try processStatePath(context, target);
    defer context.allocator.free(state_path);
    try std.Io.Dir.cwd().createDirPath(context.io, std.fs.path.dirname(state_path).?);
    var file = try std.Io.Dir.cwd().createFile(context.io, state_path, .{});
    defer file.close(context.io);
    var buffer: [128]u8 = undefined;
    var writer = file.writer(context.io, &buffer);
    try writer.interface.print("{d} {d}\n", .{ pid, start_time });
    try writer.interface.flush();
}

fn readTrackedProcess(context: *runtime.RuntimeContext, state_path: []const u8) !TrackedProcess {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        context.io,
        state_path,
        context.allocator,
        .limited(256),
    );
    defer context.allocator.free(contents);
    var fields = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    const pid_text = fields.next() orelse return error.InvalidProcessState;
    const start_text = fields.next() orelse return error.InvalidProcessState;
    if (fields.next() != null) return error.InvalidProcessState;
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    if (pid <= 0) return error.InvalidProcessState;
    return .{
        .pid = pid,
        .start_time = try std.fmt.parseInt(u64, start_text, 10),
    };
}

fn processStatePath(context: *runtime.RuntimeContext, target: []const u8) ![]const u8 {
    const base = if (xdg.getEnv(context, "XDG_RUNTIME_DIR")) |runtime_directory|
        if (runtime_directory.len > 0 and std.fs.path.isAbsolute(runtime_directory))
            runtime_directory
        else
            try xdg.stateHome(context)
    else
        try xdg.stateHome(context);
    const hash = std.hash.Wyhash.hash(0, target);
    const filename = try std.fmt.allocPrint(context.allocator, "{x}.pid", .{hash});
    defer context.allocator.free(filename);
    return std.fs.path.join(context.allocator, &.{ base, "shelly", "appimage-processes", filename });
}

fn processStartTime(context: *runtime.RuntimeContext, pid: std.posix.pid_t) !u64 {
    const path = try std.fmt.allocPrint(context.allocator, "/proc/{d}/stat", .{pid});
    defer context.allocator.free(path);
    const contents = try readPseudoFileAlloc(context, path, 16 * 1024);
    defer context.allocator.free(contents);

    const command_end = std.mem.lastIndexOfScalar(u8, contents, ')') orelse
        return error.InvalidProcessStat;
    var fields = std.mem.tokenizeScalar(u8, contents[command_end + 1 ..], ' ');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        // Tokens after the command name start at proc(5) field 3; starttime is
        // field 22, therefore token index 19.
        if (index == 19) return std.fmt.parseInt(u64, field, 10);
    }
    return error.InvalidProcessStat;
}

fn killDiscoveredAppImages(context: *runtime.RuntimeContext, target: []const u8) !bool {
    var proc = try std.Io.Dir.cwd().openDir(context.io, "/proc", .{ .iterate = true });
    defer proc.close(context.io);
    var iterator = proc.iterate();
    var killed = false;
    while (try iterator.next(context.io)) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (pid <= 0 or !try processHasAppImageEnvironment(context, pid, target)) continue;
        std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => continue,
            error.PermissionDenied => continue,
            else => return err,
        };
        killed = true;
    }
    return killed;
}

fn processHasAppImageEnvironment(
    context: *runtime.RuntimeContext,
    pid: std.posix.pid_t,
    target: []const u8,
) !bool {
    const path = try std.fmt.allocPrint(context.allocator, "/proc/{d}/environ", .{pid});
    defer context.allocator.free(path);
    const contents = readPseudoFileAlloc(context, path, 1024 * 1024) catch return false;
    defer context.allocator.free(contents);
    const expected = try std.fmt.allocPrint(context.allocator, "APPIMAGE={s}", .{target});
    defer context.allocator.free(expected);
    var variables = std.mem.splitScalar(u8, contents, 0);
    while (variables.next()) |variable| {
        if (std.mem.eql(u8, variable, expected)) return true;
    }
    return false;
}

fn readPseudoFileAlloc(
    context: *runtime.RuntimeContext,
    path: []const u8,
    max_len: usize,
) ![]u8 {
    // procfs reports a size of zero for files such as stat and environ, so
    // read the descriptor directly instead of using size-based Io helpers.
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(context.io);

    var contents: std.ArrayList(u8) = .empty;
    errdefer contents.deinit(context.allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try std.posix.read(fd, &buffer);
        if (count == 0) break;
        if (contents.items.len + count > max_len) return error.StreamTooLong;
        try contents.appendSlice(context.allocator, buffer[0..count]);
    }
    return contents.toOwnedSlice(context.allocator);
}

fn resolveAppImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    search_paths: []const []const u8,
) ![]const u8 {
    if ((std.fs.path.isAbsolute(query) or std.mem.indexOfScalar(u8, query, '/') != null) and
        std.ascii.eqlIgnoreCase(std.fs.path.extension(query), ".AppImage"))
    {
        std.Io.Dir.cwd().access(io, query, .{}) catch return RunError.AppImageNotFound;
        return allocator.dupe(u8, query);
    }

    var exact: ?[]const u8 = null;
    var exact_count: usize = 0;
    var partial: ?[]const u8 = null;
    var partial_count: usize = 0;
    errdefer {
        if (exact) |path| allocator.free(path);
        if (partial) |path| allocator.free(path);
    }
    for (search_paths) |directory| {
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".AppImage")) continue;
            const stem = std.fs.path.stem(entry.name);
            const is_exact = std.ascii.eqlIgnoreCase(entry.name, query) or
                std.ascii.eqlIgnoreCase(stem, query);
            if (!is_exact and !containsTextIgnoreCase(entry.name, query)) continue;
            const candidate = try std.fs.path.join(allocator, &.{ directory, entry.name });
            if (is_exact) {
                exact_count += 1;
                if (exact == null) exact = candidate else allocator.free(candidate);
            } else {
                partial_count += 1;
                if (partial == null) partial = candidate else allocator.free(candidate);
            }
        }
    }

    if (exact_count == 1) {
        if (partial) |path| allocator.free(path);
        return exact.?;
    }
    if (exact_count > 1 or partial_count > 1) return RunError.AmbiguousAppImage;
    if (partial) |path| return path;
    return RunError.AppImageNotFound;
}

fn containsTextIgnoreCase(value: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > value.len) return false;
    var index: usize = 0;
    while (index + query.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + query.len], query)) return true;
    }
    return false;
}

fn writeOpening(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    kill: bool,
    target: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "{s} {s}: {s}...",
        .{ if (kill) "Stopping" else "Launching", backendName(backend), target },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(context, "TransactionStart", message);
    } else {
        try colors.printLine(context, .warning, "{s}", .{message});
    }
}

fn writeCompletion(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    kill: bool,
    succeeded: bool,
) !void {
    const message = completionMessage(backend, kill, succeeded);
    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(
            context,
            if (succeeded) "TransactionDone" else "TransactionFailed",
            message,
        );
    } else if (succeeded) {
        try output.writeSuccess(context, message);
    } else {
        try output.writeFailure(context, message);
    }
}

fn completionMessage(backend: Backend, kill: bool, succeeded: bool) []const u8 {
    return switch (backend) {
        .flatpak => if (kill)
            if (succeeded) "Flatpak application stopped." else "Failed to stop Flatpak application."
        else if (succeeded) "Flatpak application launched." else "Failed to launch Flatpak application.",
        .appimage => if (kill)
            if (succeeded) "AppImage stopped." else "Failed to stop AppImage."
        else if (succeeded) "AppImage launched." else "Failed to launch AppImage.",
    };
}

fn backendName(backend: Backend) []const u8 {
    return switch (backend) {
        .flatpak => "Flatpak application",
        .appimage => "AppImage",
    };
}

fn backendForPath(path: []const u8) ?Backend {
    if (std.mem.eql(u8, path, flatpak_command_path)) return .flatpak;
    if (std.mem.eql(u8, path, appimage_command_path)) return .appimage;
    return null;
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn stringValue(config: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = config.values.get(key) orelse return null;
    return switch (value) {
        .string => |string| if (string.len > 0) string else null,
        else => null,
    };
}

fn flush(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

test "run catalog exposes Flatpak list and both backend launch and kill modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    inline for (.{ "flatpak", "appimage" }) |type_name| {
        const path = try std.fmt.allocPrint(arena.allocator(), "shelly run {s}", .{type_name});
        const command = manifest.findByPath(path).?;
        try std.testing.expectEqual(@as(usize, 1), command.arguments.len);
        try std.testing.expectEqualStrings("--kill", manifest.findOption(command, "-k").?.name);
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, type_name, "flatpak")) 0 else 1), command.arguments[0].minimumArity);
    }
    const flatpak = manifest.findByPath(flatpak_command_path).?;
    try std.testing.expectEqualStrings("--list", manifest.findOption(flatpak, "-l").?.name);
    try std.testing.expect(manifest.findOption(manifest.findByPath(appimage_command_path).?, "-l") == null);

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{ "run", "flatpak", "org.example.App" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(!optionEnabled(&outcome.dispatch, "--kill"));

    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "run", "appimage", "-k", "Editor" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(optionEnabled(&outcome.dispatch, "--kill"));

    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "run", "flatpak", "list" });
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(listRequested(&outcome.dispatch));

    const translated = try @import("../cli/shortcodes.zig").translate(
        arena.allocator(),
        &manifest,
        &.{"-Xfl"},
    );
    outcome = try parser.parse(arena.allocator(), &manifest, translated.arguments().?);
    try std.testing.expect(outcome == .dispatch);
    try std.testing.expect(listRequested(&outcome.dispatch));
    try std.testing.expectEqual(@as(usize, 0), outcome.dispatch.positionals.len);
}

test "run Flatpak list renders running instances in plain and JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const items = [_]RunningItem{.{
        .instance_id = "1234567890",
        .application_id = "org.example.Editor",
        .arch = "x86_64",
        .branch = "stable",
        .pid = 1234,
        .child_pid = 1235,
    }};
    const Capture = struct {
        items: []const RunningItem,

        fn list(self: *@This(), _: *runtime.RuntimeContext) !RunningResult {
            return .{ .items = self.items };
        }
    };
    var capture: Capture = .{ .items = &items };

    var plain_stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plain_stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &plain_stdout.writer,
        .stderr = &stderr.writer,
    };
    var outcome = try parser.parse(arena.allocator(), &manifest, &.{ "run", "flatpak", "list" });
    try std.testing.expectEqual(@as(u8, 0), try listRunningWith(&context, &outcome.dispatch, &capture));
    for ([_][]const u8{ "Application", "org.example.Editor", "1234", "Total: 1 running Flatpak" }) |value|
        try std.testing.expect(std.mem.indexOf(u8, plain_stdout.writer.buffered(), value) != null);

    var json_stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_stdout.deinit();
    context.stdout = &json_stdout.writer;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "run", "flatpak", "--list", "--json" });
    try std.testing.expectEqual(@as(u8, 0), try listRunningWith(&context, &outcome.dispatch, &capture));
    try std.testing.expectEqualStrings(
        "[{\"Application\":\"org.example.Editor\",\"Instance\":\"1234567890\",\"Pid\":1234,\"ChildPid\":1235,\"Arch\":\"x86_64\",\"Branch\":\"stable\"}]\n",
        json_stdout.writer.buffered(),
    );
}

test "run Flatpak list rejects kill mode" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{ "run", "flatpak", "list", "--kill" });
    const Unused = struct {
        fn list(_: @This(), _: *runtime.RuntimeContext) !RunningResult {
            return error.ShouldNotRun;
        }
    };
    try std.testing.expectEqual(
        @as(u8, 1),
        try listRunningWith(&tc.context, &outcome.dispatch, Unused{}),
    );
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "--list and --kill cannot be used together") != null);
}

test "run routes all four backend modes and renders completion" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const Capture = struct {
        calls: usize = 0,

        fn call(
            self: *@This(),
            _: *runtime.RuntimeContext,
            backend: Backend,
            kill: bool,
            target: []const u8,
        ) !bool {
            self.calls += 1;
            try std.testing.expectEqualStrings(if (backend == .flatpak) "Flatpak" else "Editor", target);
            try std.testing.expectEqual(kill, self.calls > 2);
            return true;
        }
    };
    var capture: Capture = .{};

    for ([_]struct { backend: []const u8, target: []const u8, kill: bool }{
        .{ .backend = "flatpak", .target = "Flatpak", .kill = false },
        .{ .backend = "appimage", .target = "Editor", .kill = false },
        .{ .backend = "flatpak", .target = "Flatpak", .kill = true },
        .{ .backend = "appimage", .target = "Editor", .kill = true },
    }) |sample| {
        const arguments: []const []const u8 = if (sample.kill)
            &.{ "run", sample.backend, "--kill", sample.target }
        else
            &.{ "run", sample.backend, sample.target };
        const outcome = try parser.parse(tc.arena.allocator(), &manifest, arguments);
        const backend = backendForPath(outcome.dispatch.command.path).?;
        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&tc.context, &outcome.dispatch, backend, &capture));
    }

    try std.testing.expectEqual(@as(usize, 4), capture.calls);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "Flatpak application launched.") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.stdout.writer.buffered(), "AppImage stopped.") != null);
}

test "run backend failures are nonzero and UI mode stays framed" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try spec.Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(tc.arena.allocator(), &manifest, &.{
        "run", "appimage", "--ui-mode", "--kill", "Editor",
    });
    const Failure = struct {
        fn call(_: @This(), _: *runtime.RuntimeContext, _: Backend, _: bool, _: []const u8) !bool {
            return false;
        }
    };

    try std.testing.expectEqual(
        @as(u8, 1),
        try executeWithRunner(&tc.context, &outcome.dispatch, .appimage, Failure{}),
    );
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, tc.stdout.writer.buffered(), "[JSON]"));
}

test "AppImage resolution prefers exact names and rejects ambiguous partials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var anchor: u8 = 0;
    const root = try std.fmt.allocPrint(allocator, "/tmp/shelly-run-appimage-test-{x}", .{@intFromPtr(&anchor)});
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    const exact_path = try std.fs.path.join(allocator, &.{ root, "Editor.AppImage" });
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, exact_path, .{});
    file.close(std.testing.io);
    const other_path = try std.fs.path.join(allocator, &.{ root, "Editor-Nightly.AppImage" });
    file = try std.Io.Dir.cwd().createFile(std.testing.io, other_path, .{});
    file.close(std.testing.io);

    const exact = try resolveAppImage(allocator, std.testing.io, "editor", &.{root});
    try std.testing.expectEqualStrings(exact_path, exact);
    try std.testing.expectError(
        RunError.AmbiguousAppImage,
        resolveAppImage(allocator, std.testing.io, "edit", &.{root}),
    );
    try std.testing.expectError(
        RunError.AppImageNotFound,
        resolveAppImage(allocator, std.testing.io, "missing", &.{root}),
    );
}

test "tracked process state validates PID and Linux start time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var anchor: u8 = 0;
    const root = try std.fmt.allocPrint(arena.allocator(), "/tmp/shelly-run-state-test-{x}", .{@intFromPtr(&anchor)});
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("HOME", root);
    try environment.put("XDG_RUNTIME_DIR", root);
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .environment = &environment,
    };

    try writeTrackedProcess(&context, "/apps/Editor.AppImage", 42, 1234);
    const state_path = try processStatePath(&context, "/apps/Editor.AppImage");
    const tracked = try readTrackedProcess(&context, state_path);
    try std.testing.expectEqual(@as(std.posix.pid_t, 42), tracked.pid);
    try std.testing.expectEqual(@as(u64, 1234), tracked.start_time);
}
