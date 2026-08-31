const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const glib = bindings.glib;
const JsonPackFrame = @import("../helpers/ui_decode.zig").JsonPackFrame;
const Scope = @import("../models/flatpak.zig").InstallLevel;
const UpdateType = @import("../models/appimage.zig").UpdateType;
const builtin = @import("builtin");
const runtime = @import("runtime.zig");

const log = std.log.scoped(.shelly_operation);
const proxy_environment_marker = "--proxy-environment-stdin";

const ProxyEnvironmentFrame = struct {
    @"$kind": []const u8 = "proxy.environment",
    http_proxy: ?[]const u8 = null,
    HTTP_PROXY: ?[]const u8 = null,
    https_proxy: ?[]const u8 = null,
    HTTPS_PROXY: ?[]const u8 = null,
    all_proxy: ?[]const u8 = null,
    ALL_PROXY: ?[]const u8 = null,
};

fn serializeProxyEnvironment(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) !?[]u8 {
    const frame: ProxyEnvironmentFrame = .{
        .http_proxy = environment.get("http_proxy"),
        .HTTP_PROXY = environment.get("HTTP_PROXY"),
        .https_proxy = environment.get("https_proxy"),
        .HTTPS_PROXY = environment.get("HTTPS_PROXY"),
        .all_proxy = environment.get("all_proxy"),
        .ALL_PROXY = environment.get("ALL_PROXY"),
    };
    if (frame.http_proxy == null and frame.HTTP_PROXY == null and
        frame.https_proxy == null and frame.HTTPS_PROXY == null and
        frame.all_proxy == null and frame.ALL_PROXY == null)
    {
        return null;
    }
    return try std.json.Stringify.valueAlloc(allocator, frame, .{});
}

pub const Event = union(enum) {
    info: struct {
        event_type: []const u8,
        message: []const u8,
        package_name: ?[]const u8,
        current: ?i64,
        total: ?i64,
    },
    err: struct {
        message: []const u8,
    },
    alpm_progress: struct {
        package_name: []const u8,
        current_download: i64,
        total_download: i64,
        progress_type: []const u8,
        percent: i64,
        stage: ?[]const u8,
        message: ?[]const u8,
    },
    flatpak_progress: struct {
        status: ?[]const u8,
        percentage: i64,
    },
    appimage_progress: struct {
        status: ?[]const u8,
        percentage: i64,
    },
    unknown: void,
};

const AlpmInfo = struct {
    @"$kind": []const u8 = "",
    EventType: []const u8 = "",
    Message: []const u8 = "",
    PackageName: ?[]const u8 = null,
    CurrentIndex: ?i64 = null,
    TotalCount: ?i64 = null,
};

const AlpmError = struct {
    @"$kind": []const u8 = "",
    ErrorMessage: []const u8 = "",
};

const AlpmProgress = struct {
    @"$kind": []const u8 = "",
    PackageName: []const u8 = "",
    CurrentDownload: i64 = 0,
    TotalDownload: i64 = 0,
    ProgressType: []const u8 = "",
    Percent: i64 = 0,
    Stage: ?[]const u8 = null,
    Message: ?[]const u8 = null,
};

const SimpleProgress = struct {
    @"$kind": []const u8 = "",
    Status: ?[]const u8 = null,
    Percentage: i64 = 0,
};

pub const Question = union(enum) {
    yes_no: struct {
        question_id: []const u8,
        question_kind: []const u8,
        question_text: []const u8,
        arguments: []const []const u8,
    },
    select_many: struct {
        question_id: []const u8,
        prompt: []const u8,
        options: []Option,
    },
    select_one: struct {
        question_id: []const u8,
        prompt: []const u8,
        options: []Option,
    },
    pkgbuild: struct {
        question_id: []const u8,
        package_name: []const u8,
        old_pkgbuild: []const u8,
        new_pkgbuild: []const u8,
        warnings: []const Warning = &.{},
        diff_lines: []const []const u8 = &.{},
        source_files: []const SourceFile = &.{},
    },
    transaction: TransactionQuestion,
};

pub const TransactionQuestion = struct {
    question_id: []const u8,
    question_text: []const u8,
    action: []const u8,
    packages: []TransactionPackage,
    total_download_size: ?u64,
    total_installed_size: ?u64,
    net_installed_size: ?i64,
};

pub const TransactionPackage = struct {
    name: []const u8,
    version: ?[]const u8,
    repository: ?[]const u8,
    package_base: ?[]const u8,
    revision: ?[]const u8,
    source: []const u8,
    role: []const u8,
    download_size: ?u64,
    installed_size: ?u64,
};

pub const Option = struct {
    index: usize,
    name: []const u8,
    description: []const u8,
    is_installed: bool,
    is_selected: bool,
};

const SelectionRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8 = "",
    DependencyName: []const u8 = "",
    QuestionText: []const u8 = "",
    Options: []OptionWire = &.{},
};

pub const SourceFile = struct {
    name: []const u8,
    content: []const u8,
};

pub const PkgbuildDiff = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8,
    PackageName: []const u8,
    OldPkgbuild: []const u8,
    NewPkgbuild: []const u8,
    Warnings: []const Warning = &.{},
    DiffLines: []const []const u8 = &.{},
    SourceFiles: ?std.json.ArrayHashMap([]const u8) = null,
};

pub const Warning = struct {
    Tool: []const u8 = "",
    Severity: []const u8 = "",
    Hook: []const u8 = "",
    MatchedLine: []const u8 = "",
    Message: []const u8 = "",
};

const OptionWire = struct {
    Index: usize = 0,
    Name: []const u8 = "",
    Description: []const u8 = "",
    IsInstalled: bool = false,
    IsSelected: bool = false,
};

const YesNoRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8 = "",
    QuestionKind: []const u8 = "",
    QuestionText: []const u8 = "",
    Arguments: []const []const u8 = &.{},
};

pub const TransactionRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8 = "",
    QuestionText: []const u8 = "",
    Action: []const u8 = "",
    Packages: []TransactionPackageWire = &.{},
    TotalDownloadSize: ?u64 = null,
    TotalInstalledSize: ?u64 = null,
    NetInstalledSize: ?i64 = null,
};

const TransactionPackageWire = struct {
    Name: []const u8 = "",
    Version: ?[]const u8 = null,
    Repository: ?[]const u8 = null,
    PackageBase: ?[]const u8 = null,
    Revision: ?[]const u8 = null,
    Source: []const u8 = "",
    Role: []const u8 = "",
    DownloadSize: ?u64 = null,
    InstalledSize: ?u64 = null,
};

pub const PendingQuestion = struct {
    arena: std.heap.ArenaAllocator,
    operation: *ShellyOperation,
    request: Question,
    completed: bool = false,
    on_dismiss: ?*const fn (ctx: *anyopaque) void = null,
    dismiss_ctx: ?*anyopaque = null,

    pub fn questionId(self: *const PendingQuestion) []const u8 {
        return switch (self.request) {
            .yes_no => |q| q.question_id,
            .select_many => |q| q.question_id,
            .select_one => |q| q.question_id,
            .pkgbuild => |q| q.question_id,
            .transaction => |q| q.question_id,
        };
    }

    pub fn destroy(self: *PendingQuestion) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
};

const Envelope = struct {
    @"$kind": []const u8 = "",
};

pub const ShellyCommands = struct {
    pub fn install(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "install");
        try argv.append(alloc, "standard");
        for (names) |n| try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn upgrade(alloc: std.mem.Allocator, flatpak: bool, aur: bool, standard: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;

        try argv.append(alloc, "upgrade");
        try argv.append(alloc, "all");
        if (!flatpak) try argv.append(alloc, "--no-flatpak");
        if (!aur) try argv.append(alloc, "--no-aur");
        if (!standard) try argv.append(alloc, "--no-repo");
        return argv.toOwnedSlice(alloc);
    }

    pub fn sync_db(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "sync");
        try argv.append(alloc, "--force");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_flatpak(alloc: std.mem.Allocator, names: []const u8, remote: Scope, remote_name: []const u8) ![]const []const u8 {
        return install_flatpak_ex(alloc, names, remote, remote_name, false);
    }

    pub fn install_flatpak_ex(alloc: std.mem.Allocator, names: []const u8, remote: Scope, remote_name: []const u8, is_runtime: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (names.len > 0) try argv.append(alloc, names);
        if (remote == .user) try argv.append(alloc, "--user");
        if (remote_name.len > 0) {
            try argv.append(alloc, "--remote");
            try argv.append(alloc, remote_name);
        }
        if (is_runtime) try argv.append(alloc, "--runtime");
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_flatpak(alloc: std.mem.Allocator, names: []const u8, config_removal: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "remove");
        try argv.append(alloc, "flatpak");
        if (names.len > 0) try argv.append(alloc, names);
        if (config_removal) try argv.append(alloc, "--remove-config");
        try argv.append(alloc, "--remove-unused");
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_remote(alloc: std.mem.Allocator, name: []const u8, remote: Scope) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "sync");
        try argv.append(alloc, "flatpak");
        try argv.append(alloc, "remote");
        try argv.append(alloc, "remove");
        if (name.len > 0) try argv.append(alloc, name);
        try argv.append(alloc, "--system");
        try argv.append(alloc, if (remote == .system) "true" else "false");
        return argv.toOwnedSlice(alloc);
    }

    pub fn add_remote(alloc: std.mem.Allocator, name: []const u8, url: []const u8, scope: [:0]const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "sync");
        try argv.append(alloc, "flatpak");
        try argv.append(alloc, "remote");
        try argv.append(alloc, "add");
        if (name.len > 0) try argv.append(alloc, name);
        try argv.append(alloc, "--remote-url");
        try argv.append(alloc, url);
        if (!std.mem.eql(u8, scope, "system")) try argv.append(alloc, "--system");
        if (!std.mem.eql(u8, scope, "system")) try argv.append(alloc, "false");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_local_flatpak_ref(alloc: std.mem.Allocator, path: []const u8, user: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (path.len > 0) try argv.append(alloc, path);
        try argv.append(alloc, "--ref-file");
        if (user) try argv.append(alloc, "--user");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_local_flatpak_bundle(alloc: std.mem.Allocator, path: []const u8, user: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (path.len > 0) try argv.append(alloc, path);
        try argv.append(alloc, "--bundle");
        if (user) try argv.append(alloc, "--user");
        return argv.toOwnedSlice(alloc);
    }

    pub fn fix_permissions(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "utility");
        try argv.append(alloc, "--fix-permissions");
        return argv.toOwnedSlice(alloc);
    }

    pub fn purify(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "purify");
        try argv.append(alloc, "standard");
        try argv.append(alloc, "--orphans");
        return argv.toOwnedSlice(alloc);
    }

    pub fn clean_cache(alloc: std.mem.Allocator, keep_str: []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "purify");
        try argv.append(alloc, "standard");
        try argv.append(alloc, "--cache");
        try argv.append(alloc, keep_str);
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_aur(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "install");
        try argv.append(alloc, "aur");
        for (names) |n| try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_appimage(
        alloc: std.mem.Allocator,
        path: []const u8,
    ) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "install");
        try argv.append(alloc, "appimage");
        if (path.len > 0) try argv.append(alloc, path);
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_appimage(alloc: std.mem.Allocator, name: []const u8, remove_config: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "remove");
        try argv.append(alloc, "appimage");
        if (name.len > 0) try argv.append(alloc, name);
        if (remove_config) try argv.append(alloc, "--remove-config");
        return argv.toOwnedSlice(alloc);
    }

    pub fn upgrade_appimages(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "upgrade");
        try argv.append(alloc, "appimage");
        return argv.toOwnedSlice(alloc);
    }

    pub fn sync_appimage(alloc: std.mem.Allocator, name: ?[]const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "sync");
        try argv.append(alloc, "appimage");
        if (name) |n| if (n.len > 0) try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn configure_appimage(
        alloc: std.mem.Allocator,
        name: []const u8,
        url: []const u8,
        update_type: UpdateType,
        prerelease: bool,
    ) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, "sync");
        try argv.append(alloc, "appimage");
        try argv.append(alloc, name);
        try argv.append(alloc, url);
        try argv.append(alloc, update_type.toCliString());
        if (prerelease) try argv.append(alloc, "--prerelease");
        return argv.toOwnedSlice(alloc);
    }
};

pub const ShellyOperation = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    child: std.process.Child,
    reader: ?std.Thread = null,
    on_event: *const fn (ctx: *anyopaque, event: Event) void,
    on_question: *const fn (ctx: *anyopaque, pending: *PendingQuestion) void,
    ctx: *anyopaque,
    on_done: *const fn (ctx: *anyopaque, exit_code: u8) void,

    pub fn init(
        allocator: std.mem.Allocator,
        on_event: *const fn (ctx: *anyopaque, event: Event) void,
        on_done: *const fn (ctx: *anyopaque, exit_code: u8) void,
        on_question: *const fn (ctx: *anyopaque, pending: *PendingQuestion) void,
        ctx: *anyopaque,
    ) ShellyOperation {
        return .{
            .allocator = allocator,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .io = undefined,
            .child = undefined,
            .on_event = on_event,
            .on_done = on_done,
            .on_question = on_question,
            .ctx = ctx,
        };
    }

    fn build_full_argv(self: *ShellyOperation, args: []const []const u8) ![]const []const u8 {
        const shelly_bin = if (builtin.mode == .Debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";
        var full = try self.allocator.alloc([]const u8, args.len + 2);
        full[0] = shelly_bin;
        @memcpy(full[1 .. 1 + args.len], args);
        full[full.len - 1] = "--ui-mode";

        return full;
    }

    pub fn start(self: *ShellyOperation, args: []const []const u8) !void {
        const full = try self.build_full_argv(args);
        defer self.allocator.free(full);
        try self.spawn_and_read(full, null);
    }

    pub fn startPrivileged(self: *ShellyOperation, args: []const []const u8) !void {
        const full = try self.build_full_argv(args);
        defer self.allocator.free(full);
        const proxy_environment = try serializeProxyEnvironment(self.allocator, runtime.environ_map);
        defer if (proxy_environment) |json| self.allocator.free(json);

        const marker_count: usize = if (proxy_environment != null) 1 else 0;
        var withpk = try self.allocator.alloc([]const u8, full.len + 1 + marker_count);
        defer self.allocator.free(withpk);
        withpk[0] = "pkexec";
        @memcpy(withpk[1 .. 1 + full.len], full);
        if (proxy_environment != null) withpk[withpk.len - 1] = proxy_environment_marker;
        try self.spawn_and_read(withpk, proxy_environment);
    }

    fn spawn_and_read(
        self: *ShellyOperation,
        argv: []const []const u8,
        startup_frame: ?[]const u8,
    ) !void {
        if (builtin.mode == .Debug) {
            if (std.mem.join(self.allocator, " ", argv)) |command| {
                defer self.allocator.free(command);
                log.debug("argv: {s}", .{command});
            } else |_| {
                log.debug("argv: {d} arguments", .{argv.len});
            }
        }

        // pkexec sanitizes the environment. Privileged starts restore only the
        // proxy variables through the startup frame written below.
        self.child = try std.process.spawn(self.io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .environ_map = runtime.environ_map });
        errdefer self.child.kill(self.io);
        if (startup_frame) |json| try self.writeAnswerFrame(json);
        self.reader = try std.Thread.spawn(.{}, reader_loop, .{self});
    }

    pub fn answer(self: *ShellyOperation, response: []const u8) !void {
        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeStreamingAll(self.io, response);
        try stdin.writeStreamingAll(self.io, "\n");
    }

    pub fn cancel(self: *ShellyOperation) void {
        self.child.kill(self.io);
    }

    fn reader_loop(self: *ShellyOperation) void {
        const stdout = self.child.stdout orelse return;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = stdout.readStreaming(self.io, &.{&read_buf}) catch break;
            if (n == 0) break;

            buf.appendSlice(self.allocator, read_buf[0..n]) catch break;

            while (JsonPackFrame.nextFrame(buf.items)) |frame| {
                post_event(self, frame.payload);
                const remaining = buf.items.len - frame.consumed;
                std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[frame.consumed..]);
                buf.shrinkRetainingCapacity(remaining);
            }
        }

        const term = self.child.wait(self.io) catch |err| {
            log.debug("reader_loop: wait error: {t}", .{err});
            post_done(self, 255);
            return;
        };
        const code: u8 = switch (term) {
            .exited => |code| code,
            .signal => |signal| @truncate(128 + @intFromEnum(signal)),
            .stopped, .unknown => 1,
        };

        post_done(self, code);
    }

    fn post_event(self: *ShellyOperation, base64_payload: []const u8) void {
        const json = JsonPackFrame.decodeBase64(self.allocator, base64_payload) catch return;

        const msg = self.allocator.create(EventMsg) catch {
            self.allocator.free(json);
            return;
        };
        msg.* = .{ .op = self, .json = json };
        _ = glib.idleAdd(&onEventIdle, msg);
    }

    fn post_done(self: *ShellyOperation, exit_code: u8) void {
        const msg = self.allocator.create(DoneMsg) catch return;
        msg.* = .{ .op = self, .exit_code = exit_code };
        _ = glib.idleAdd(&onDoneIdle, msg);
    }

    pub fn answerYesNo(self: *ShellyOperation, question_id: []const u8, accept: bool) !void {
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        try json_buf.appendSlice(self.allocator, "{\"$kind\":\"a.yesno\",\"QuestionId\":\"");
        try json_buf.appendSlice(self.allocator, question_id);
        try json_buf.appendSlice(self.allocator, "\",\"Accept\":");
        try json_buf.appendSlice(self.allocator, if (accept) "true" else "false");
        try json_buf.appendSlice(self.allocator, "}");
        try self.writeAnswerFrame(json_buf.items);
    }

    pub fn answerTransaction(self: *ShellyOperation, question_id: []const u8, accept: bool) !void {
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        try json_buf.appendSlice(self.allocator, "{\"$kind\":\"a.transaction\",\"QuestionId\":\"");
        try json_buf.appendSlice(self.allocator, question_id);
        try json_buf.appendSlice(self.allocator, "\",\"Accept\":");
        try json_buf.appendSlice(self.allocator, if (accept) "true" else "false");
        try json_buf.appendSlice(self.allocator, "}");
        try self.writeAnswerFrame(json_buf.items);
    }

    pub fn answerOptDeps(self: *ShellyOperation, question_id: []const u8, selected: []const usize) !void {
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        try json_buf.appendSlice(self.allocator, "{\"$kind\":\"a.optdeps\",\"QuestionId\":\"");
        try json_buf.appendSlice(self.allocator, question_id);
        try json_buf.appendSlice(self.allocator, "\",\"SelectedIndices\":[");
        for (selected, 0..) |idx, i| {
            if (i > 0) try json_buf.append(self.allocator, ',');
            var numbuf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&numbuf, "{d}", .{idx}) catch continue;
            try json_buf.appendSlice(self.allocator, s);
        }
        try json_buf.appendSlice(self.allocator, "]}");

        try self.writeAnswerFrame(json_buf.items);
    }

    pub fn answerPkgbuildDiff(self: *ShellyOperation, question_id: []const u8, accepted: bool) !void {
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        try json_buf.appendSlice(self.allocator, "{\"$kind\":\"a.pkgbuilddiff\",\"QuestionId\":\"");
        try json_buf.appendSlice(self.allocator, question_id);
        try json_buf.appendSlice(self.allocator, "\",\"ProceedWithUpdate\":");
        try json_buf.appendSlice(self.allocator, if (accepted) "true" else "false");
        try json_buf.append(self.allocator, '}');
        try self.writeAnswerFrame(json_buf.items);
    }

    pub fn answerProvider(self: *ShellyOperation, question_id: []const u8, selected: usize) !void {
        var json_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        var numbuf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&numbuf, "{d}", .{selected}) catch "0";

        try json_buf.appendSlice(self.allocator, "{\"$kind\":\"a.provider\",\"QuestionId\":\"");
        try json_buf.appendSlice(self.allocator, question_id);
        try json_buf.appendSlice(self.allocator, "\",\"SelectedIndex\":");
        try json_buf.appendSlice(self.allocator, s);
        try json_buf.appendSlice(self.allocator, "}");

        try self.writeAnswerFrame(json_buf.items);
    }

    fn writeAnswerFrame(self: *ShellyOperation, json: []const u8) !void {
        const b64_len = std.base64.standard.Encoder.calcSize(json.len);
        const b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, json);

        var frame: std.ArrayListUnmanaged(u8) = .empty;
        defer frame.deinit(self.allocator);
        try frame.appendSlice(self.allocator, "[JSON]");
        try frame.appendSlice(self.allocator, b64);
        try frame.appendSlice(self.allocator, "[/JSON]\n");

        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeStreamingAll(self.io, frame.items);
    }
};

const EventMsg = struct { op: *ShellyOperation, json: []u8 };

const DoneMsg = struct { op: *ShellyOperation, exit_code: u8 };

fn onEventIdle(data: ?*anyopaque) callconv(.c) c_int {
    const msg: *EventMsg = @ptrCast(@alignCast(data.?));
    defer {
        msg.op.allocator.free(msg.json);
        msg.op.allocator.destroy(msg);
    }
    const op = msg.op;
    const alloc = op.allocator;

    const env = std.json.parseFromSlice(Envelope, alloc, msg.json, .{ .ignore_unknown_fields = true }) catch return 0;
    defer env.deinit();
    const kind = env.value.@"$kind";

    if (std.mem.eql(u8, kind, "q.yesno")) {
        if (parseYesNo(op, msg.json) catch null) |p| op.on_question(op.ctx, p);
    } else if (std.mem.eql(u8, kind, "q.transaction")) {
        if (parseTransaction(op, msg.json) catch null) |p| op.on_question(op.ctx, p);
    } else if (std.mem.eql(u8, kind, "q.optdeps") or std.mem.eql(u8, kind, "q.provider")) {
        if (parseSelection(op, msg.json, kind) catch null) |p| op.on_question(op.ctx, p);
    } else if (std.mem.eql(u8, kind, "q.pkgbuilddiff")) {
        if (parsePkgbuildDiff(op, msg.json) catch null) |p| {
            op.on_question(op.ctx, p);
        }
    } else {
        dispatchEvent(op, alloc, msg.json, kind);
    }

    return 0;
}

fn newPending(op: *ShellyOperation) !*PendingQuestion {
    const p = try op.allocator.create(PendingQuestion);
    p.* = .{
        .arena = std.heap.ArenaAllocator.init(op.allocator),
        .operation = op,
        .request = undefined,
    };
    return p;
}

fn parsePkgbuildDiff(op: *ShellyOperation, json: []const u8) !?*PendingQuestion {
    const parsed = try std.json.parseFromSlice(PkgbuildDiff, op.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const pending = try newPending(op);
    errdefer pending.destroy();
    const qa = pending.arena.allocator();

    const warnings = try qa.alloc(Warning, parsed.value.Warnings.len);
    for (parsed.value.Warnings, warnings) |warning, *target| {
        target.* = .{
            .Tool = try qa.dupe(u8, warning.Tool),
            .Severity = try qa.dupe(u8, warning.Severity),
            .Hook = try qa.dupe(u8, warning.Hook),
            .MatchedLine = try qa.dupe(u8, warning.MatchedLine),
            .Message = try qa.dupe(u8, warning.Message),
        };
    }
    const diff_lines = try qa.alloc([]const u8, parsed.value.DiffLines.len);
    for (parsed.value.DiffLines, diff_lines) |line, *target| {
        target.* = try qa.dupe(u8, line);
    }

    const source_count = if (parsed.value.SourceFiles) |files|
        files.map.count()
    else
        0;

    const source_files = try qa.alloc(SourceFile, source_count);
    if (parsed.value.SourceFiles) |files_values| {
        var files = files_values;
        var file_iterator = files.map.iterator();
        var index: usize = 0;
        while (file_iterator.next()) |entry| : (index += 1) {
            source_files[index] = SourceFile{
                .name = try qa.dupe(u8, entry.key_ptr.*),
                .content = try qa.dupe(u8, entry.value_ptr.*),
            };
        }
    }

    pending.request = .{ .pkgbuild = .{
        .question_id = try qa.dupe(u8, parsed.value.QuestionId),
        .package_name = try qa.dupe(u8, parsed.value.PackageName),
        .old_pkgbuild = try qa.dupe(u8, parsed.value.OldPkgbuild),
        .new_pkgbuild = try qa.dupe(u8, parsed.value.NewPkgbuild),
        .warnings = warnings,
        .diff_lines = diff_lines,
        .source_files = source_files,
    } };

    return pending;
}

fn parseYesNo(op: *ShellyOperation, json: []const u8) !?*PendingQuestion {
    const e = try std.json.parseFromSlice(
        YesNoRequest,
        op.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer e.deinit();

    const pending = try newPending(op);
    errdefer pending.destroy();
    const qa = pending.arena.allocator();

    const arguments = try qa.alloc(
        []const u8,
        e.value.Arguments.len,
    );

    for (e.value.Arguments, arguments) |argument, *owned| {
        owned.* = try qa.dupe(u8, argument);
    }

    pending.request = .{ .yes_no = .{
        .question_id = try qa.dupe(u8, e.value.QuestionId),
        .question_kind = try qa.dupe(u8, e.value.QuestionKind),
        .question_text = try qa.dupe(u8, e.value.QuestionText),
        .arguments = arguments,
    } };

    return pending;
}


fn parseTransaction(op: *ShellyOperation, json: []const u8) !?*PendingQuestion {
    const e = try std.json.parseFromSlice(TransactionRequest, op.allocator, json, .{ .ignore_unknown_fields = true });
    defer e.deinit();

    const pending = try newPending(op);
    errdefer pending.destroy();
    const qa = pending.arena.allocator();

    const packages = try qa.alloc(TransactionPackage, e.value.Packages.len);
    for (e.value.Packages, packages) |package, *target| target.* = .{
        .name = qa.dupe(u8, package.Name) catch "",
        .version = dupeOptional(qa, package.Version),
        .repository = dupeOptional(qa, package.Repository),
        .package_base = dupeOptional(qa, package.PackageBase),
        .revision = dupeOptional(qa, package.Revision),
        .source = qa.dupe(u8, package.Source) catch "",
        .role = qa.dupe(u8, package.Role) catch "",
        .download_size = package.DownloadSize,
        .installed_size = package.InstalledSize,
    };

    pending.request = .{ .transaction = .{
        .question_id = try qa.dupe(u8, e.value.QuestionId),
        .question_text = qa.dupe(u8, e.value.QuestionText) catch "",
        .action = qa.dupe(u8, e.value.Action) catch "",
        .packages = packages,
        .total_download_size = e.value.TotalDownloadSize,
        .total_installed_size = e.value.TotalInstalledSize,
        .net_installed_size = e.value.NetInstalledSize,
    } };
    return pending;
}

fn parseSelection(op: *ShellyOperation, json: []const u8, kind: []const u8) !?*PendingQuestion {
    const e = try std.json.parseFromSlice(SelectionRequest, op.allocator, json, .{ .ignore_unknown_fields = true });
    defer e.deinit();

    const pending = try newPending(op);
    errdefer pending.destroy();
    const qa = pending.arena.allocator();

    const opts = try qa.alloc(Option, e.value.Options.len);
    for (e.value.Options, 0..) |o, i| {
        opts[i] = .{
            .index = o.Index,
            .name = qa.dupe(u8, o.Name) catch "",
            .description = qa.dupe(u8, o.Description) catch "",
            .is_installed = o.IsInstalled,
            .is_selected = o.IsSelected,
        };
    }

    const qid = try qa.dupe(u8, e.value.QuestionId);

    if (std.mem.eql(u8, kind, "q.optdeps")) {
        pending.request = .{ .select_many = .{
            .question_id = qid,
            .prompt = qa.dupe(u8, e.value.QuestionText) catch "",
            .options = opts,
        } };
    } else if (std.mem.eql(u8, kind, "q.provider")) {
        pending.request = .{ .select_one = .{
            .question_id = qid,
            .prompt = qa.dupe(u8, e.value.QuestionText) catch "",
            .options = opts,
        } };
    } else {
        pending.request = .{ .select_one = .{
            .question_id = qid,
            .prompt = qa.dupe(u8, e.value.DependencyName) catch "",
            .options = opts,
        } };
    }
    return pending;
}

fn dispatchEvent(op: *ShellyOperation, alloc: std.mem.Allocator, json: []const u8, kind: []const u8) void {
    if (std.mem.eql(u8, kind, "alpm.info")) {
        const e = std.json.parseFromSlice(AlpmInfo, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        op.on_event(op.ctx, .{ .info = .{
            .event_type = e.value.EventType,
            .message = e.value.Message,
            .package_name = e.value.PackageName,
            .current = e.value.CurrentIndex,
            .total = e.value.TotalCount,
        } });
    } else if (std.mem.eql(u8, kind, "alpm.error")) {
        const e = std.json.parseFromSlice(AlpmError, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        op.on_event(op.ctx, .{ .err = .{ .message = e.value.ErrorMessage } });
    } else if (std.mem.eql(u8, kind, "alpm.progress")) {
        const e = std.json.parseFromSlice(AlpmProgress, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        op.on_event(op.ctx, .{ .alpm_progress = .{
            .package_name = e.value.PackageName,
            .stage = e.value.Stage,
            .current_download = e.value.CurrentDownload,
            .total_download = e.value.TotalDownload,
            .progress_type = e.value.ProgressType,
            .percent = clampPercent(e.value.Percent),
            .message = e.value.Message,
        } });
    } else if (std.mem.eql(u8, kind, "flatpak.progress")) {
        const e = std.json.parseFromSlice(SimpleProgress, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        op.on_event(op.ctx, .{ .flatpak_progress = .{
            .status = e.value.Status,
            .percentage = clampPercent(e.value.Percentage),
        } });
    } else if (std.mem.eql(u8, kind, "appimage.progress")) {
        const e = std.json.parseFromSlice(SimpleProgress, alloc, json, .{ .ignore_unknown_fields = true }) catch return;
        defer e.deinit();
        op.on_event(op.ctx, .{ .appimage_progress = .{
            .status = e.value.Status,
            .percentage = clampPercent(e.value.Percentage),
        } });
    } else {
        op.on_event(op.ctx, .unknown);
    }
}

fn clampPercent(p: i64) i64 {
    if (p < 0) return 0;
    if (p > 100) return 100;
    return p;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) ?[]const u8 {
    const string = value orelse return null;
    return allocator.dupe(u8, string) catch null;
}

fn onDoneIdle(data: ?*anyopaque) callconv(.c) c_int {
    const msg: *DoneMsg = @ptrCast(@alignCast(data.?));
    const alloc = msg.op.allocator;
    const op = msg.op;
    const code = msg.exit_code;
    alloc.destroy(msg);
    op.on_done(op.ctx, code);
    return 0;
}

test "progress percentages are clamped to the GTK protocol range" {
    try std.testing.expectEqual(@as(i64, 0), clampPercent(-1));
    try std.testing.expectEqual(@as(i64, 0), clampPercent(0));
    try std.testing.expectEqual(@as(i64, 37), clampPercent(37));
    try std.testing.expectEqual(@as(i64, 100), clampPercent(100));
    try std.testing.expectEqual(@as(i64, 100), clampPercent(101));
}

test "flatpak install argv adds --user only for user scope" {
    const system_argv = try ShellyCommands.install_flatpak(std.testing.allocator, "org.example.App", .system, "");
    defer std.testing.allocator.free(system_argv);
    try std.testing.expectEqualSlices([]const u8, &.{ "install", "flatpak", "org.example.App" }, system_argv);

    const user_argv = try ShellyCommands.install_flatpak(std.testing.allocator, "org.example.App", .user, "");
    defer std.testing.allocator.free(user_argv);
    try std.testing.expectEqualSlices([]const u8, &.{ "install", "flatpak", "org.example.App", "--user" }, user_argv);
}

test "flatpak install argv passes --remote when a remote name is supplied" {
    const argv = try ShellyCommands.install_flatpak(std.testing.allocator, "org.example.App", .system, "flathub");
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualSlices([]const u8, &.{ "install", "flatpak", "org.example.App", "--remote", "flathub" }, argv);

    const with_user = try ShellyCommands.install_flatpak_ex(std.testing.allocator, "org.example.App", .user, "flathub-beta", false);
    defer std.testing.allocator.free(with_user);
    try std.testing.expectEqualSlices([]const u8, &.{ "install", "flatpak", "org.example.App", "--user", "--remote", "flathub-beta" }, with_user);
}

test "flatpak addon install argv marks addon refs as runtimes" {
    const argv = try ShellyCommands.install_flatpak_ex(std.testing.allocator, "org.example.App.Plugin", .user, "", true);
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualSlices([]const u8, &.{ "install", "flatpak", "org.example.App.Plugin", "--user", "--runtime" }, argv);
}

test "appimage install argv relies on the CLI config for the install path" {
    const argv = try ShellyCommands.install_appimage(std.testing.allocator, "/tmp/NiceApp.AppImage");
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualSlices([]const u8, &.{ "install", "appimage", "/tmp/NiceApp.AppImage" }, argv);
}

test "proxy environment serialization preserves standard variable names" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("http_proxy", "http://user:p@ss@proxy.example:443/");
    try environment.put("HTTPS_PROXY", "http://secure-proxy.example:8080/");
    try environment.put("ALL_PROXY", "http://fallback.example:3128/");
    try environment.put("PATH", "/usr/bin");

    const json = (try serializeProxyEnvironment(std.testing.allocator, &environment)).?;
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(ProxyEnvironmentFrame, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("proxy.environment", parsed.value.@"$kind");
    try std.testing.expectEqualStrings("http://user:p@ss@proxy.example:443/", parsed.value.http_proxy.?);
    try std.testing.expectEqualStrings("http://secure-proxy.example:8080/", parsed.value.HTTPS_PROXY.?);
    try std.testing.expectEqualStrings("http://fallback.example:3128/", parsed.value.ALL_PROXY.?);
}

test "proxy environment serialization is absent without proxy variables" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin");
    try std.testing.expect(try serializeProxyEnvironment(std.testing.allocator, &environment) == null);
}
