//! Frontend-neutral operation protocol baseline, adapted from the GTK client.
const std = @import("std");
const diagnostics = @import("diagnostics");
const JsonPackFrame = @import("ui_decode.zig").JsonPackFrame;
const Scope = @import("flatpak.zig").InstallLevel;
const UpdateType = @import("appimage.zig").UpdateType;

pub const ElevatedInstallRequest = struct {
    shelly_bin: []const u8,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
    backend: []const u8,
    password: []const u8,
};

pub const InstallOperation = struct {
    arena: std.heap.ArenaAllocator,
    request: ElevatedInstallRequest,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: InstallResult = .{},

    pub fn start(request: ElevatedInstallRequest) !*InstallOperation {
        const self = try std.heap.page_allocator.create(InstallOperation);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .arena = .init(std.heap.page_allocator),
            .request = request,
        };
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        self.request.shelly_bin = try alloc.dupe(u8, request.shelly_bin);
        self.request.name = try alloc.dupe(u8, request.name);
        self.request.backend = try alloc.dupe(u8, request.backend);
        self.request.password = try alloc.dupe(u8, request.password);
        errdefer @memset(@constCast(self.request.password), 0);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *InstallOperation) void {
        {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            self.result = elevatedInstall(threaded.io(), std.heap.page_allocator, self.request);
            @memset(@constCast(self.request.password), 0);
        }
        self.done.store(true, .release);
    }

    pub fn poll(self: *InstallOperation) ?*const InstallResult {
        if (!self.done.load(.acquire)) return null;
        return &self.result;
    }

    pub fn deinit(self: *InstallOperation) void {
        if (self.thread) |thread| thread.join();
        self.result.deinit(std.heap.page_allocator);
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

pub const InstallResult = struct {
    failed: bool = false,
    error_detail: []const u8 = "",

    pub fn deinit(self: *InstallResult, allocator: std.mem.Allocator) void {
        if (self.error_detail.len > 0) allocator.free(self.error_detail);
        self.* = undefined;
    }
};

/// Blocking prototype install path. The caller schedules background execution.
/// Retains sudo password input and automatic confirmation until the interactive
/// transport and terminal authentication replace this path.
pub fn elevatedInstall(io: std.Io, alloc: std.mem.Allocator, request: ElevatedInstallRequest) InstallResult {
    var result: InstallResult = .{};
    const argv = alloc.alloc([]const u8, 10) catch {
        result.failed = true;
        return result;
    };
    defer alloc.free(argv);
    argv[0] = "sudo";
    argv[1] = "-S";
    argv[2] = "-p";
    argv[3] = "";
    argv[4] = request.shelly_bin;
    argv[5] = "install";
    argv[6] = request.backend;
    argv[7] = request.name;
    argv[8] = "--no-confirm";
    argv[9] = "--ui-mode";

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = request.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        result.error_detail = alloc.dupe(u8, "Could not start sudo to authorize installation of the requested package.") catch "";
        result.failed = true;
        return result;
    };
    defer child.kill(io);

    // Feed the password to sudo, then close stdin. The writes fail
    // harmlessly if sudo already exited (e.g. wrong password); the
    // error then surfaces via stderr below.
    {
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_writer = child.stdin.?.writer(io, &stdin_buffer);
        const stdin = &stdin_writer.interface;
        stdin.writeAll(request.password) catch {};
        stdin.writeByte('\n') catch {};
        stdin.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    // Drain both streams concurrently, mirroring std.process.run
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    var read_failed = false;
    while (true) {
        multi_reader.fill(64, .none) catch |err| {
            if (err != error.EndOfStream) read_failed = true;
            break;
        };
    }
    if (read_failed) {
        result.error_detail = alloc.dupe(u8, "Could not read the installation command output for the requested package.") catch "";
        result.failed = true;
        return result;
    }

    const term = child.wait(io) catch {
        result.error_detail = alloc.dupe(u8, "Could not collect the installation result for the requested package. Its final status could not be confirmed.") catch "";
        result.failed = true;
        return result;
    };

    if (term != .exited or term.exited != 0) {
        const stderr = multi_reader.toOwnedSlice(1) catch &.{};
        const stdout = multi_reader.toOwnedSlice(0) catch &.{};
        defer if (stderr.len > 0) alloc.free(stderr);
        defer if (stdout.len > 0) alloc.free(stdout);
        result.error_detail = (JsonPackFrame.failureMessage(alloc, stdout) catch null) orelse
            (diagnostics.sanitizeAlloc(alloc, if (stderr.len > 0) std.mem.trim(u8, stderr, " \t\r\n") else "Could not install the requested package. Shelly returned no error details. Review the command output before retrying.") catch "");
        result.failed = true;
    }
    return result;
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
    unknown: []const u8,
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
    Level: []const u8 = "Error",
    Recoverable: bool = false,
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

pub const TransactionMigration = struct {
    path: []const u8,
    destination: []const u8,
    source: ?[]const u8 = null,
    origin: []const u8,
};

pub const TransactionQuestion = struct {
    migrations: []const TransactionMigration = &.{},
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
    QuestionId: []const u8,
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
    QuestionId: []const u8,
    QuestionKind: []const u8 = "",
    QuestionText: []const u8 = "",
    Arguments: []const []const u8 = &.{},
};

pub const TransactionRequest = struct {
    @"$kind": []const u8 = "",
    QuestionId: []const u8,
    QuestionText: []const u8 = "",
    Action: []const u8 = "",
    Packages: []TransactionPackageWire = &.{},
    Migrations: []TransactionMigration = &.{},
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

pub const Message = union(enum) {
    event: Event,
    question: Question,
};

pub const OwnedMessage = struct {
    arena: std.heap.ArenaAllocator,
    value: Message,

    pub fn deinit(self: *OwnedMessage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn parseWire(comptime T: type, allocator: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn questionId(question: Question) []const u8 {
    return switch (question) {
        inline else => |q| q.question_id,
    };
}

pub fn decodePayload(allocator: std.mem.Allocator, payload: []const u8) !OwnedMessage {
    const json = try JsonPackFrame.decodeBase64(allocator, payload);
    defer allocator.free(json);
    return decodeJson(allocator, json);
}

pub fn decodeJson(allocator: std.mem.Allocator, json: []const u8) !OwnedMessage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const envelope = try parseWire(struct { @"$kind": []const u8 }, alloc, json);
    const kind = envelope.@"$kind";
    const value: Message = if (std.mem.startsWith(u8, kind, "q.")) blk: {
        const question = try decodeQuestion(alloc, json, kind);
        const id = questionId(question);
        // The CLI parses question IDs as decimal u64 strings.
        if (id.len == 0) return error.InvalidQuestionId;
        for (id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidQuestionId;
        _ = std.fmt.parseInt(u64, id, 10) catch return error.InvalidQuestionId;
        break :blk .{ .question = question };
    } else .{ .event = try decodeEvent(alloc, json, kind) };
    return .{ .arena = arena, .value = value };
}

fn decodeQuestion(alloc: std.mem.Allocator, json: []const u8, kind: []const u8) !Question {
    if (std.mem.eql(u8, kind, "q.yesno")) {
        const q = try parseWire(YesNoRequest, alloc, json);
        return .{ .yes_no = .{
            .question_id = q.QuestionId,
            .question_kind = q.QuestionKind,
            .question_text = q.QuestionText,
            .arguments = q.Arguments,
        } };
    }
    if (std.mem.eql(u8, kind, "q.transaction")) {
        const q = try parseWire(TransactionRequest, alloc, json);
        const packages = try alloc.alloc(TransactionPackage, q.Packages.len);
        for (q.Packages, packages) |package, *target| target.* = .{
            .name = package.Name,
            .version = package.Version,
            .repository = package.Repository,
            .package_base = package.PackageBase,
            .revision = package.Revision,
            .source = package.Source,
            .role = package.Role,
            .download_size = package.DownloadSize,
            .installed_size = package.InstalledSize,
        };
        return .{ .transaction = .{
            .question_id = q.QuestionId,
            .question_text = q.QuestionText,
            .action = q.Action,
            .packages = packages,
            .migrations = q.Migrations,
            .total_download_size = q.TotalDownloadSize,
            .total_installed_size = q.TotalInstalledSize,
            .net_installed_size = q.NetInstalledSize,
        } };
    }
    if (std.mem.eql(u8, kind, "q.provider") or std.mem.eql(u8, kind, "q.optdeps")) {
        const q = try parseWire(SelectionRequest, alloc, json);
        const options = try alloc.alloc(Option, q.Options.len);
        for (q.Options, options) |option, *target| target.* = .{
            .index = option.Index,
            .name = option.Name,
            .description = option.Description,
            .is_installed = option.IsInstalled,
            .is_selected = option.IsSelected,
        };
        if (std.mem.eql(u8, kind, "q.provider")) return .{ .select_one = .{
            .question_id = q.QuestionId,
            .prompt = q.DependencyName,
            .options = options,
        } };
        return .{ .select_many = .{
            .question_id = q.QuestionId,
            .prompt = q.QuestionText,
            .options = options,
        } };
    }
    if (std.mem.eql(u8, kind, "q.pkgbuilddiff")) {
        const q = try parseWire(PkgbuildDiff, alloc, json);
        const count = if (q.SourceFiles) |files| files.map.count() else 0;
        const files = try alloc.alloc(SourceFile, count);
        if (q.SourceFiles) |source| {
            var iterator = source.map.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                files[index] = .{ .name = entry.key_ptr.*, .content = entry.value_ptr.* };
            }
        }
        return .{ .pkgbuild = .{
            .question_id = q.QuestionId,
            .package_name = q.PackageName,
            .old_pkgbuild = q.OldPkgbuild,
            .new_pkgbuild = q.NewPkgbuild,
            .warnings = q.Warnings,
            .diff_lines = q.DiffLines,
            .source_files = files,
        } };
    }
    return error.UnsupportedQuestion;
}

fn decodeEvent(alloc: std.mem.Allocator, json: []const u8, kind: []const u8) !Event {
    if (std.mem.eql(u8, kind, "alpm.info")) {
        const e = try parseWire(AlpmInfo, alloc, json);
        return .{ .info = .{
            .event_type = e.EventType,
            .message = e.Message,
            .package_name = e.PackageName,
            .current = e.CurrentIndex,
            .total = e.TotalCount,
        } };
    }
    if (std.mem.eql(u8, kind, "alpm.error")) {
        const e = try parseWire(AlpmError, alloc, json);
        if (e.Recoverable or !std.mem.eql(u8, e.Level, "Error")) return .{ .info = .{
            .event_type = "Warning",
            .message = e.ErrorMessage,
            .package_name = null,
            .current = null,
            .total = null,
        } };
        return .{ .err = .{ .message = e.ErrorMessage } };
    }
    if (std.mem.eql(u8, kind, "alpm.progress")) {
        const e = try parseWire(AlpmProgress, alloc, json);
        return .{ .alpm_progress = .{
            .package_name = e.PackageName,
            .current_download = e.CurrentDownload,
            .total_download = e.TotalDownload,
            .progress_type = e.ProgressType,
            .percent = std.math.clamp(e.Percent, 0, 100),
            .stage = e.Stage,
            .message = e.Message,
        } };
    }
    if (std.mem.eql(u8, kind, "flatpak.progress") or std.mem.eql(u8, kind, "appimage.progress")) {
        const e = try parseWire(SimpleProgress, alloc, json);
        if (std.mem.eql(u8, kind, "flatpak.progress")) return .{ .flatpak_progress = .{
            .status = e.Status,
            .percentage = std.math.clamp(e.Percentage, 0, 100),
        } };
        return .{ .appimage_progress = .{
            .status = e.Status,
            .percentage = std.math.clamp(e.Percentage, 0, 100),
        } };
    }
    return .{ .unknown = kind };
}

pub const Answer = union(enum) {
    yes_no: bool,
    transaction: bool,
    optional_dependencies: []const usize,
    pkgbuild: bool,
    provider: usize,
};

pub fn encodeAnswer(allocator: std.mem.Allocator, question_id: []const u8, answer: Answer) ![]u8 {
    if (question_id.len == 0) return error.InvalidQuestionId;
    for (question_id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidQuestionId;
    _ = std.fmt.parseInt(u64, question_id, 10) catch return error.InvalidQuestionId;
    const json = switch (answer) {
        .yes_no => |accept| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.yesno", .QuestionId = question_id, .Accept = accept }, .{}),
        .transaction => |accept| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.transaction", .QuestionId = question_id, .Accept = accept }, .{}),
        .optional_dependencies => |selected| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.optdeps", .QuestionId = question_id, .SelectedIndices = selected }, .{}),
        .pkgbuild => |accept| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.pkgbuilddiff", .QuestionId = question_id, .ProceedWithUpdate = accept }, .{}),
        .provider => |selected| try std.json.Stringify.valueAlloc(allocator, .{ .@"$kind" = "a.provider", .QuestionId = question_id, .SelectedIndex = selected }, .{}),
    };
    defer allocator.free(json);
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, json);
    return std.fmt.allocPrint(allocator, "[JSON]{s}[/JSON]\n", .{encoded});
}

pub const ShellyCommands = struct {
    pub fn install(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "standard");
        for (names) |n| try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn upgrade(alloc: std.mem.Allocator, flatpak: bool, aur: bool, standard: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);

        try argv.append(alloc, "upgrade");
        try argv.append(alloc, "all");
        if (!flatpak) try argv.append(alloc, "--no-flatpak");
        if (!aur) try argv.append(alloc, "--no-aur");
        if (!standard) try argv.append(alloc, "--no-repo");
        return argv.toOwnedSlice(alloc);
    }

    pub fn sync_db(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "--force");
        return argv.toOwnedSlice(alloc);
    }

    pub fn installFlatpak(alloc: std.mem.Allocator, names: []const u8, remote: Scope, remote_name: []const u8) ![]const []const u8 {
        return installFlatpakEx(alloc, names, remote, remote_name, false);
    }

    pub fn installFlatpakEx(alloc: std.mem.Allocator, names: []const u8, remote: Scope, remote_name: []const u8, is_runtime: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
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

    pub fn removeFlatpak(alloc: std.mem.Allocator, names: []const u8, config_removal: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "remove");
        try argv.append(alloc, "flatpak");
        if (names.len > 0) try argv.append(alloc, names);
        if (config_removal) try argv.append(alloc, "--remove-config");
        try argv.append(alloc, "--remove-unused");
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_remote(alloc: std.mem.Allocator, name: []const u8, remote: Scope) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
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
        errdefer argv.deinit(alloc);
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
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (path.len > 0) try argv.append(alloc, path);
        try argv.append(alloc, "--ref-file");
        if (user) try argv.append(alloc, "--user");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_local_flatpak_bundle(alloc: std.mem.Allocator, path: []const u8, user: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "flatpak");
        if (path.len > 0) try argv.append(alloc, path);
        try argv.append(alloc, "--bundle");
        if (user) try argv.append(alloc, "--user");
        return argv.toOwnedSlice(alloc);
    }

    pub fn fix_permissions(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "utility");
        try argv.append(alloc, "--fix-permissions");
        return argv.toOwnedSlice(alloc);
    }

    pub fn purify(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "purify");
        try argv.append(alloc, "standard");
        try argv.append(alloc, "--orphans");
        return argv.toOwnedSlice(alloc);
    }

    pub fn clean_cache(alloc: std.mem.Allocator, keep_str: []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "purify");
        try argv.append(alloc, "standard");
        try argv.append(alloc, "--cache");
        try argv.append(alloc, keep_str);
        try argv.append(alloc, "--aur-cache");
        return argv.toOwnedSlice(alloc);
    }

    pub fn install_aur(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
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
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "install");
        try argv.append(alloc, "appimage");
        if (path.len > 0) try argv.append(alloc, path);
        return argv.toOwnedSlice(alloc);
    }

    pub fn remove_appimage(alloc: std.mem.Allocator, name: []const u8, remove_config: bool) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "remove");
        try argv.append(alloc, "appimage");
        if (name.len > 0) try argv.append(alloc, name);
        if (remove_config) try argv.append(alloc, "--remove-config");
        return argv.toOwnedSlice(alloc);
    }

    pub fn upgrade_appimages(alloc: std.mem.Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "upgrade");
        try argv.append(alloc, "appimage");
        return argv.toOwnedSlice(alloc);
    }

    pub fn sync_appimage(alloc: std.mem.Allocator, name: ?[]const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "appimage");
        if (name) |n| if (n.len > 0) try argv.append(alloc, n);
        return argv.toOwnedSlice(alloc);
    }

    pub fn configure_appimage_environment(alloc: std.mem.Allocator, name: []const u8, json: []const u8) ![]const []const u8 {
        return alloc.dupe([]const u8, &.{ "config", "appimage", name, "--replace-env", json });
    }

    pub fn configure_appimage(
        alloc: std.mem.Allocator,
        name: []const u8,
        url: []const u8,
        update_type: UpdateType,
        prerelease: bool,
    ) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer argv.deinit(alloc);
        try argv.append(alloc, "sync");
        try argv.append(alloc, "appimage");
        try argv.append(alloc, name);
        try argv.append(alloc, url);
        try argv.append(alloc, update_type.toCliString());
        if (prerelease) try argv.append(alloc, "--prerelease");
        return argv.toOwnedSlice(alloc);
    }
};

test "operation questions own their data after input is released" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        \\{"$kind":"q.yesno","QuestionId":"1","QuestionKind":"PackageConflict","QuestionText":"Continue?","Arguments":["editor"]}
        ,
        \\{"$kind":"q.transaction","QuestionId":"2","Action":"install","Packages":[{"Name":"editor","Repository":"extra","Source":"standard","Role":"requested"}],"Migrations":[{"path":"old","destination":"new","origin":"test"}]}
        ,
        \\{"$kind":"q.provider","QuestionId":"3","DependencyName":"java-runtime","Options":[{"Index":0,"Name":"jdk","IsInstalled":true}]}
        ,
        \\{"$kind":"q.optdeps","QuestionId":"4","QuestionText":"Optional dependencies","Options":[{"Index":1,"Name":"plugin","IsSelected":true}]}
        ,
        \\{"$kind":"q.pkgbuilddiff","QuestionId":"5","PackageName":"editor","OldPkgbuild":"old","NewPkgbuild":"new","Warnings":[{"Message":"Review this"}],"SourceFiles":{"editor.install":"post_install() {}"}}
        ,
    };
    for (fixtures, 1..) |fixture, id| {
        const input = try allocator.dupe(u8, fixture);
        var message = decodeJson(allocator, input) catch |err| {
            allocator.free(input);
            return err;
        };
        allocator.free(input);
        defer message.deinit();
        var buffer: [20]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "{d}", .{id});
        try std.testing.expectEqualStrings(expected, questionId(message.value.question));
        switch (message.value.question) {
            .yes_no => |q| try std.testing.expectEqualStrings("editor", q.arguments[0]),
            .transaction => |q| {
                try std.testing.expectEqualStrings("extra", q.packages[0].repository.?);
                try std.testing.expectEqualStrings("new", q.migrations[0].destination);
            },
            .select_one => |q| try std.testing.expect(q.options[0].is_installed),
            .select_many => |q| try std.testing.expect(q.options[0].is_selected),
            .pkgbuild => |q| {
                try std.testing.expectEqualStrings("Review this", q.warnings[0].Message);
                try std.testing.expectEqualStrings("post_install() {}", q.source_files[0].content);
            },
        }
    }
}

test "operation events preserve outcomes and distinguish warnings from errors" {
    const allocator = std.testing.allocator;
    var cancelled = try decodeJson(allocator, "{\"$kind\":\"alpm.info\",\"EventType\":\"TransactionCancelled\",\"Message\":\"Cancelled\"}");
    defer cancelled.deinit();
    try std.testing.expectEqualStrings("TransactionCancelled", cancelled.value.event.info.event_type);
    var warning = try decodeJson(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Warning\",\"Recoverable\":true}");
    defer warning.deinit();
    try std.testing.expectEqualStrings("Warning", warning.value.event.info.message);
    var failure = try decodeJson(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Failed\"}");
    defer failure.deinit();
    try std.testing.expectEqualStrings("Failed", failure.value.event.err.message);
    var progress = try decodeJson(allocator, "{\"$kind\":\"alpm.progress\",\"Percent\":120,\"Stage\":\"download\"}");
    defer progress.deinit();
    try std.testing.expectEqual(@as(i64, 100), progress.value.event.alpm_progress.percent);
    var flatpak = try decodeJson(allocator, "{\"$kind\":\"flatpak.progress\",\"Percentage\":50}");
    defer flatpak.deinit();
    try std.testing.expectEqual(@as(i64, 50), flatpak.value.event.flatpak_progress.percentage);
    var appimage = try decodeJson(allocator, "{\"$kind\":\"appimage.progress\",\"Percentage\":-1}");
    defer appimage.deinit();
    try std.testing.expectEqual(@as(i64, 0), appimage.value.event.appimage_progress.percentage);
    var unknown = try decodeJson(allocator, "{\"$kind\":\"future.event\"}");
    defer unknown.deinit();
    try std.testing.expectEqualStrings("future.event", unknown.value.event.unknown);
    try std.testing.expectError(error.UnsupportedQuestion, decodeJson(allocator, "{\"$kind\":\"q.future\",\"QuestionId\":\"1\"}"));
    try std.testing.expectError(error.InvalidQuestionId, decodeJson(allocator, "{\"$kind\":\"q.yesno\",\"QuestionId\":\"bad\"}"));
    try std.testing.expectError(error.MissingField, decodeJson(allocator, "{\"$kind\":\"q.yesno\"}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, decodeJson(allocator, "{"));
}

test "operation answers match CLI framing and answer fields" {
    const allocator = std.testing.allocator;
    const answers = [_]Answer{ .{ .yes_no = true }, .{ .transaction = false }, .{ .optional_dependencies = &.{ 0, 2 } }, .{ .pkgbuild = true }, .{ .provider = 1 } };
    const kinds = [_][]const u8{ "a.yesno", "a.transaction", "a.optdeps", "a.pkgbuilddiff", "a.provider" };
    const fields = [_][]const u8{ "Accept", "Accept", "SelectedIndices", "ProceedWithUpdate", "SelectedIndex" };
    for (answers, kinds, fields) |answer, kind, field| {
        const frame = try encodeAnswer(allocator, "42", answer);
        defer allocator.free(frame);
        try std.testing.expect(std.mem.endsWith(u8, frame, "[/JSON]\n"));
        const payload = JsonPackFrame.extractPayload(frame).?;
        const json = try JsonPackFrame.decodeBase64(allocator, payload);
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqualStrings(kind, object.get("$kind").?.string);
        try std.testing.expectEqualStrings("42", object.get("QuestionId").?.string);
        const value = object.get(field).?;
        switch (answer) {
            .yes_no, .transaction, .pkgbuild => |accept| try std.testing.expectEqual(accept, value.bool),
            .provider => |index| try std.testing.expectEqual(@as(i64, @intCast(index)), value.integer),
            .optional_dependencies => |indices| {
                try std.testing.expectEqual(indices.len, value.array.items.len);
                for (indices, value.array.items) |index, item| try std.testing.expectEqual(@as(i64, @intCast(index)), item.integer);
            },
        }
    }
    try std.testing.expectError(error.InvalidQuestionId, encodeAnswer(allocator, "1\"", .{ .yes_no = true }));
}

test "operation payload decoding accepts framed transaction events" {
    const allocator = std.testing.allocator;
    const json = "{\"$kind\":\"alpm.info\",\"EventType\":\"TransactionDone\"}";
    const payload = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer allocator.free(payload);
    _ = std.base64.standard.Encoder.encode(payload, json);
    var message = try decodePayload(allocator, payload);
    defer message.deinit();
    try std.testing.expectEqualStrings("TransactionDone", message.value.event.info.event_type);
}

test "operation builders preserve package operands and source options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const native = try ShellyCommands.install(allocator, &.{ "extra/editor", "package with spaces" });
    try std.testing.expectEqualStrings("extra/editor", native[2]);
    try std.testing.expectEqualStrings("package with spaces", native[3]);
    const flatpak = try ShellyCommands.installFlatpakEx(allocator, "org.example.Runtime", .user, "flathub", true);
    try std.testing.expectEqualStrings("--user", flatpak[3]);
    try std.testing.expectEqualStrings("--remote", flatpak[4]);
    try std.testing.expectEqualStrings("--runtime", flatpak[6]);
    const environment = try ShellyCommands.configure_appimage_environment(allocator, "Editor", "{\"KEY\":\" a=b \"}");
    try std.testing.expectEqualStrings("{\"KEY\":\" a=b \"}", environment[4]);
    const source = try ShellyCommands.configure_appimage(allocator, "Editor", "owner/repo", .GitHub, true);
    try std.testing.expectEqualStrings("GitHub", source[4]);
    try std.testing.expectEqualStrings("--prerelease", source[5]);
}

test "operation worker owns inputs and joins on launch failure" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    // No real sudo or package operation can be launched by this test.
    try env.put("PATH", "/nonexistent-shelly-operation-test");
    var name = [_]u8{ 't', 'e', 's', 't' };
    const operation = try InstallOperation.start(.{
        .shelly_bin = "/nonexistent-shelly",
        .environ_map = &env,
        .name = &name,
        .backend = "standard",
        .password = "",
    });
    defer operation.deinit();
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("test", operation.request.name);
    operation.thread.?.join();
    operation.thread = null;
    const result = operation.poll() orelse return error.ExpectedCompletion;
    try std.testing.expect(result.failed);
    try std.testing.expect(result.error_detail.len > 0);

    // Cleanup must also join a worker whose result has never been polled.
    const unpolled = try InstallOperation.start(operation.request);
    unpolled.deinit();
}
