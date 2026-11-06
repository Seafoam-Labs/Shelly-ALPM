const std = @import("std");
const Io = std.Io;
const Package = @import("../models/packages.zig").Package;
const AurPackage = @import("../models/packages.zig").AurPackage;
const PkgBuild = @import("../models/pkgbuild.zig").PkgBuild;
const Remote = @import("../models/flatpak.zig").Remote;
const Flatpak = @import("../models/flatpak.zig").Flatpak;
const AppstreamApp = @import("../models/flatpak.zig").AppstreamApp;
const CheckUpdates = @import("../models/sync.zig").CheckUpdates;
const JsonPackFrame = @import("ui_decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;
const runtime = @import("../runtime.zig");

// Query responses may include informational frames before or after their data.
// The caller owns the returned parse, independently of the process output.
fn decodeQuery(comptime T: type, allocator: std.mem.Allocator, output: []const u8, native_search: bool) !std.json.Parsed(T) {
    var data: ?std.json.Parsed(T) = null;
    errdefer if (data) |*parsed| parsed.deinit();
    var empty_search = false;
    var frames = JsonPackFrame.frames(output);
    while (frames.next()) |payload| {
        const json = try JsonPackFrame.decodeBase64(allocator, payload);
        defer allocator.free(json);
        const frame = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer frame.deinit();

        if (frame.value == .object) {
            if (frame.value.object.get("$kind")) |kind| {
                if (kind != .string) return error.UnexpectedFrame;
                if (std.mem.eql(u8, kind.string, "alpm.error")) return error.CommandFailed;
                if (!std.mem.eql(u8, kind.string, "alpm.info")) return error.UnsupportedFrame;
                // Current native search emits no array for zero results. Keep this
                // compatibility rule specific to its exact completion message.
                if (native_search) {
                    const event = frame.value.object.get("EventType");
                    const message = frame.value.object.get("Message");
                    if (event != null and event.? == .string and
                        std.mem.eql(u8, event.?.string, "InformationalOutput") and
                        message != null and message.? == .string and
                        std.mem.eql(u8, message.?.string, "Showing 0 search results"))
                    {
                        empty_search = true;
                    }
                }
                continue;
            }
        }
        if (data != null) return error.MultipleDataFrames;
        data = try std.json.parseFromSlice(T, allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
    if (data) |parsed| return parsed;
    if (native_search and empty_search) {
        return std.json.parseFromSlice(T, allocator, "[]", .{ .allocate = .alloc_always });
    }
    return error.NoDataFrame;
}

var preview_query_mutex: Io.Mutex = .init;

pub const ShellyCli = struct {
    binary: ?[]const u8 = null,
    environment: ?*const std.process.Environ.Map = null,
    allocator: std.mem.Allocator,
    io: Io,

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        const shelly_bin = self.binary orelse runtime.shellyBin();

        var argv = try self.allocator.alloc([]const u8, args.len + 2);
        defer self.allocator.free(argv);
        argv[0] = shelly_bin;
        @memcpy(argv[1 .. 1 + args.len], args);
        argv[argv.len - 1] = "--ui-mode";

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = self.environment orelse runtime.environ_map,
        });
        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            return error.CommandFailed;
        }

        return result;
    }

    fn runPreviewQuery(self: ShellyCli, args: []const []const u8) !RunResult {
        preview_query_mutex.lockUncancelable(self.io);
        defer preview_query_mutex.unlock(self.io);
        return self.run(args);
    }

    pub fn get_packages(self: ShellyCli, show_hidden: bool) !std.json.Parsed([]Package) {
        const result = try self.run(&.{if (show_hidden) "-Ssvw" else "-Ssv"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]Package, self.allocator, result.stdout, true);
    }

    pub fn get_installed_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{"-Ls"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]Package, self.allocator, result.stdout, true);
    }

    /// Read-only usability probe through the CLI's backend loader. An empty
    /// remote list succeeds; missing/incompatible backends or query errors fail.
    pub fn probe_flatpak(self: ShellyCli) !void {
        const result = try self.run(&.{ "list", "flatpak", "remote" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const remotes = try decodeQuery([]Remote, self.allocator, result.stdout, false);
        defer remotes.deinit();
    }

    pub fn get_installed_flatpaks(self: ShellyCli) !std.json.Parsed([]Flatpak) {
        const result = try self.run(&.{"-Lf"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return decodeQuery([]Flatpak, self.allocator, result.stdout, false);
    }

    pub fn get_remote_appstream_apps(self: ShellyCli) !std.json.Parsed([]AppstreamApp) {
        const result = try self.run(&.{ "list", "flatpak", "remote", "all" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AppstreamApp, self.allocator, result.stdout, false);
    }

    /// Searches the AUR via the CLI. The caller owns the parsed result.
    pub const AurSource = struct { AurUrl: []const u8 = "https://aur.archlinux.org" };

    pub fn get_aur_source(self: ShellyCli) !std.json.Parsed(AurSource) {
        const result = try self.run(&.{ "config", "get", "AurUrl" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return decodeQuery(AurSource, self.allocator, result.stdout, false);
    }

    pub fn search_aur(self: ShellyCli, query: []const u8) !std.json.Parsed([]AurPackage) {
        const result = try self.run(&.{ "search", "aur", query });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AurPackage, self.allocator, result.stdout, false);
    }

    pub fn list_aur_installed(self: ShellyCli) !std.json.Parsed([]AurPackage) {
        const result = try self.runPreviewQuery(&.{ "list", "aur" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AurPackage, self.allocator, result.stdout, false);
    }

    pub fn fetch_pkgbuild(self: ShellyCli, name: []const u8) !std.json.Parsed([]PkgBuild) {
        return self.fetchPkgbuild(name, .preview);
    }

    pub const PkgbuildFetchMode = enum {
        preview,
        atoll_preview,
        atoll_scan,
    };

    pub fn fetchPkgbuild(self: ShellyCli, name: []const u8, mode: PkgbuildFetchMode) !std.json.Parsed([]PkgBuild) {
        const args: []const []const u8 = switch (mode) {
            .preview => &.{ "search", "aur", name, "--pkgbuild" },
            .atoll_preview => &.{ "search", "aur", name, "--pkgbuild", "--aur-url", "https://atoll.seafoam-labs.org" },
            .atoll_scan => &.{ "search", "aur", name, "--pkgbuild", "--scan-pkgbuild", "--aur-url", "https://atoll.seafoam-labs.org" },
        };
        const result = try self.run(args);
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);

        return decodeQuery([]PkgBuild, self.allocator, result.stdout, false);
    }

    fn sourceUpdates(self: ShellyCli, comptime T: type, source: []const u8) !std.json.Parsed([]T) {
        const args: []const []const u8 = &.{ "list-updates", source };
        const result = if (std.mem.eql(u8, source, "standard") or std.mem.eql(u8, source, "aur"))
            try self.runPreviewQuery(args)
        else
            try self.run(args);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return decodeQuery([]T, self.allocator, result.stdout, false);
    }

    /// Query only enabled sources, without changing shared CLI configuration.
    pub fn check_updates_for_sources(self: ShellyCli, aur_enabled: bool, flatpak_enabled: bool) !std.json.Parsed(CheckUpdates) {
        const sync = @import("../models/sync.zig");
        const native = try self.sourceUpdates(sync.CheckUpdatesPackage, "standard");
        defer native.deinit();
        var aur: ?std.json.Parsed([]sync.CheckUpdatesAur) = null;
        defer if (aur) |*parsed| parsed.deinit();
        var flatpak: ?std.json.Parsed([]sync.CheckUpdatesFlatpak) = null;
        defer if (flatpak) |*parsed| parsed.deinit();
        if (aur_enabled) aur = try self.sourceUpdates(sync.CheckUpdatesAur, "aur");
        if (flatpak_enabled) flatpak = try self.sourceUpdates(sync.CheckUpdatesFlatpak, "flatpak");
        const combined: CheckUpdates = .{ .Packages = native.value, .Aur = if (aur) |parsed| parsed.value else &.{}, .Flatpak = if (flatpak) |parsed| parsed.value else &.{} };
        const json = try std.json.Stringify.valueAlloc(self.allocator, combined, .{});
        defer self.allocator.free(json);
        return std.json.parseFromSlice(CheckUpdates, self.allocator, json, .{ .allocate = .alloc_always });
    }
};

test "get_packages" {
    // Live CLI smoke test: requires runtime.setup and configured local sources.
    if (runtime.data_home.len == 0) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_packages(false);

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {s}\n", .{ parsed.value[0].Name, parsed.value[0].Version });
}

test "probe_flatpak" {
    // Live CLI smoke test: requires runtime.setup and configured local sources.
    if (runtime.data_home.len == 0) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    try cli.probe_flatpak();
}

test "get_flatpaks" {
    // Live CLI smoke test: requires runtime.setup and configured local sources.
    if (runtime.data_home.len == 0) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_installed_flatpaks();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {t}\n", .{ parsed.value[0].Name, parsed.value[0].InstallLevel });
}

fn queryTestFrame(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, json);
    return std.fmt.allocPrint(allocator, "[JSON]{s}[/JSON]\n", .{encoded});
}

test "query decoding owns package strings and handles informational frames" {
    const allocator = std.testing.allocator;
    const info = try queryTestFrame(allocator, "{\"$kind\":\"alpm.info\",\"Message\":\"Searching\"}");
    defer allocator.free(info);
    const data = try queryTestFrame(allocator, "[{\"Name\":\"editor\",\"Description\":\"Contains \\\"$kind\\\" text\"}]");
    defer allocator.free(data);
    const output = try std.mem.concat(allocator, u8, &.{ info, data, info });
    const parsed = decodeQuery([]Package, allocator, output, true) catch |err| {
        allocator.free(output);
        return err;
    };
    allocator.free(output);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("editor", parsed.value[0].Name);
}

test "query decoding distinguishes empty native search from missing data" {
    const allocator = std.testing.allocator;
    const empty = try queryTestFrame(allocator, "{\"$kind\":\"alpm.info\",\"EventType\":\"InformationalOutput\",\"Message\":\"Showing 0 search results\"}");
    defer allocator.free(empty);
    const parsed = try decodeQuery([]Package, allocator, empty, true);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.len);
    try std.testing.expectError(error.NoDataFrame, decodeQuery([]Package, allocator, empty, false));
    try std.testing.expectError(error.NoDataFrame, decodeQuery([]Package, allocator, "", true));
    const malformed = try queryTestFrame(allocator, "{");
    defer allocator.free(malformed);
    try std.testing.expectError(error.UnexpectedEndOfInput, decodeQuery([]Package, allocator, malformed, true));
}

test "query decoding rejects trailing errors and unsupported questions" {
    const allocator = std.testing.allocator;
    const data = try queryTestFrame(allocator, "[{\"Name\":\"editor\"}]");
    defer allocator.free(data);
    const failure = try queryTestFrame(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Failed\"}");
    defer allocator.free(failure);
    const output = try std.mem.concat(allocator, u8, &.{ data, failure });
    defer allocator.free(output);
    try std.testing.expectError(error.CommandFailed, decodeQuery([]Package, allocator, output, true));
    const question = try queryTestFrame(allocator, "{\"$kind\":\"q.yesno\",\"QuestionId\":\"1\"}");
    defer allocator.free(question);
    try std.testing.expectError(error.UnsupportedFrame, decodeQuery([]Package, allocator, question, true));
}

test "Flatpak probe decoding accepts empty remotes but rejects backend failure" {
    const allocator = std.testing.allocator;
    const empty = try queryTestFrame(allocator, "[]");
    defer allocator.free(empty);
    const remotes = try decodeQuery([]Remote, allocator, empty, false);
    defer remotes.deinit();
    try std.testing.expectEqual(@as(usize, 0), remotes.value.len);
    const failure = try queryTestFrame(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Flatpak backend unavailable\"}");
    defer allocator.free(failure);
    try std.testing.expectError(error.CommandFailed, decodeQuery([]Remote, allocator, failure, false));
    try std.testing.expectError(error.NoDataFrame, decodeQuery([]Remote, allocator, "", false));
}

test "AUR source configuration decodes the CLI single-value frame" {
    const frame = try queryTestFrame(std.testing.allocator, "{\"AurUrl\":\"https://atoll.seafoam-labs.org\"}");
    defer std.testing.allocator.free(frame);
    const parsed = try decodeQuery(ShellyCli.AurSource, std.testing.allocator, frame, false);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://atoll.seafoam-labs.org", parsed.value.AurUrl);
}

test "failed query captures child output and returns an error without terminal diagnostics" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = std.testing.io, .binary = "/bin/sh", .environment = &env };
    try std.testing.expectError(error.CommandFailed, cli.run(&.{ "-c", "printf 'query output'; printf 'backend initialization failed' >&2; exit 1" }));
    const recovered = try cli.run(&.{ "-c", "printf 'recovered'" });
    defer std.testing.allocator.free(recovered.stdout);
    defer std.testing.allocator.free(recovered.stderr);
    try std.testing.expectEqualStrings("recovered", recovered.stdout);
    try std.testing.expectEqualStrings("", recovered.stderr);
}

test "preview queries cannot overlap their child processes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var ready: std.atomic.Value(usize) = .init(0);
    var failures: std.atomic.Value(usize) = .init(0);
    const Worker = struct {
        fn run(path: []const u8, barrier: *std.atomic.Value(usize), failed: *std.atomic.Value(usize)) void {
            const alloc = std.heap.page_allocator;
            var threaded: Io.Threaded = .init(alloc, .{});
            defer threaded.deinit();
            var env: std.process.Environ.Map = .init(alloc);
            defer env.deinit();
            const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io(), .binary = "/bin/sh", .environment = &env };
            _ = barrier.fetchAdd(1, .acq_rel);
            while (barrier.load(.acquire) < 2) std.atomic.spinLoopHint();
            // An overlapping process would fail to create the exclusive marker.
            const result = cli.runPreviewQuery(&.{ "-c", "mkdir \"$1/active\" || exit 23; sleep 0.05; rmdir \"$1/active\"", "fixture", path }) catch {
                _ = failed.fetchAdd(1, .monotonic);
                return;
            };
            alloc.free(result.stdout);
            alloc.free(result.stderr);
        }
    };
    const first = try std.Thread.spawn(.{}, Worker.run, .{ directory, &ready, &failures });
    const second = std.Thread.spawn(.{}, Worker.run, .{ directory, &ready, &failures }) catch |err| {
        _ = ready.fetchAdd(1, .acq_rel);
        first.join();
        return err;
    };
    first.join();
    second.join();
    try std.testing.expectEqual(@as(usize, 0), failures.load(.acquire));
}
