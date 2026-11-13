const std = @import("std");
const Io = std.Io;
const Package = @import("../models/packages.zig").Package;
const AurPackage = @import("../models/packages.zig").AurPackage;
const PkgBuild = @import("../models/pkgbuild.zig").PkgBuild;
const Remote = @import("../models/flatpak.zig").Remote;
const Flatpak = @import("../models/flatpak.zig").Flatpak;
const AppstreamApp = @import("../models/flatpak.zig").AppstreamApp;
const ParsedCheckUpdates = @import("../models/sync.zig").ParsedCheckUpdates;
const AppImage = @import("../models/appimage.zig").AppImage;
const AppImageUpdate = @import("../models/appimage.zig").AppImageUpdate;
const UpdateType = @import("../models/appimage.zig").UpdateType;
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
    aur_url: ?[]const u8 = null,
    environment: ?*const std.process.Environ.Map = null,
    allocator: std.mem.Allocator,
    io: Io,

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        const shelly_bin = self.binary orelse runtime.shellyBin();

        var argv = try self.allocator.alloc([]const u8, args.len + 2 + @as(usize, if (self.aur_url != null) 2 else 0));
        defer self.allocator.free(argv);
        argv[0] = shelly_bin;
        @memcpy(argv[1 .. 1 + args.len], args);
        if (self.aur_url) |url| {
            argv[1 + args.len] = "--aur-url";
            argv[2 + args.len] = url;
        }
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

    pub fn configure_appimage_updates(self: ShellyCli, name: []const u8, source: []const u8, update_type: UpdateType, prerelease: bool) !void {
        const args = [_][]const u8{ "sync", "appimage", name, if (update_type == .None) "" else std.mem.trim(u8, source, &std.ascii.whitespace), update_type.toCliString(), "--prerelease" };
        const result = try self.run(args[0..if (prerelease) args.len else args.len - 1]);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        try checkConfigurationResult(self.allocator, result.stdout);
    }

    pub fn get_installed_appimages(self: ShellyCli) !std.json.Parsed([]AppImage) {
        const result = try self.run(&.{ "list", "appimage" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AppImage, self.allocator, result.stdout, false);
    }

    pub fn get_remote_appstream_apps(self: ShellyCli) !std.json.Parsed([]AppstreamApp) {
        const result = try self.run(&.{ "list", "flatpak", "remote", "all" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AppstreamApp, self.allocator, result.stdout, false);
    }

    pub const AurSource = struct { AurUrl: []const u8 };

    pub fn get_aur_source(self: ShellyCli) !std.json.Parsed(AurSource) {
        const result = try self.run(&.{ "config", "get", "AurUrl" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return decodeQuery(AurSource, self.allocator, result.stdout, false);
    }

    pub fn set_aur_url(self: ShellyCli, url: []const u8) !void {
        const result = try self.run(&.{ "config", "set", "AurUrl", url });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const parsed = decodeQuery(std.json.Value, self.allocator, result.stdout, false) catch |err| switch (err) {
            error.NoDataFrame => return,
            else => return err,
        };
        parsed.deinit();
    }

    /// Searches the AUR via the CLI. The caller owns the parsed result.
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
    pub fn check_updates_for_sources(self: ShellyCli, aur_enabled: bool, flatpak_enabled: bool, appimage_enabled: bool) !ParsedCheckUpdates {
        const sync = @import("../models/sync.zig");
        var flatpak: UpdateQuery(sync.CheckUpdatesFlatpak, "flatpak") = .{ .cli = self };
        defer flatpak.deinit();
        var appimage: UpdateQuery(AppImageUpdate, "appimage") = .{ .cli = self };
        defer appimage.deinit();
        if (flatpak_enabled) try flatpak.start();
        if (appimage_enabled) try appimage.start();
        const native = try self.sourceUpdates(sync.CheckUpdatesPackage, "standard");
        errdefer native.deinit();
        var aur: ?std.json.Parsed([]sync.CheckUpdatesAur) = null;
        errdefer if (aur) |*parsed| parsed.deinit();
        if (aur_enabled) aur = try self.sourceUpdates(sync.CheckUpdatesAur, "aur");
        flatpak.join();
        appimage.join();
        if (flatpak.failure) |err| return err;
        if (appimage.failure) |err| return err;
        const result = ParsedCheckUpdates.fromSources(native, aur, flatpak.result, appimage.result);
        flatpak.result = null;
        appimage.result = null;
        return result;
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

test "appimage listing decodes representative metadata" {
    const allocator = std.testing.allocator;
    const info = try queryTestFrame(allocator, "{\"$kind\":\"alpm.info\",\"Message\":\"Listing AppImages\"}");
    defer allocator.free(info);
    const data = try queryTestFrame(allocator,
        \\[{"Name":"Blender","DesktopName":"Blender","Version":"4.2.0","IconName":"blender","Description":"3D modeling","SizeOnDisk":268435456,"UpdateURl":"seafoam-labs/blender","RawUpdateInfo":"","RepoOwner":"seafoam-labs","RepoName":"blender","UpdateType":2,"AllowPrerelease":false,"EnvironmentVariables":[],"CommandLineArgs":null,"Path":"/home/user/.local/bin/blender.AppImage"},{"Name":"Nightly Editor","Version":"3.1","SizeOnDisk":188743680,"UpdateType":6,"UpdateURl":"zsync|https://nightly.example.dev/latest/Editor.AppImage.zsync","Path":"/home/user/.local/bin/Editor.AppImage"}]
    );
    defer allocator.free(data);
    const output = try std.mem.concat(allocator, u8, &.{ info, data });

    const parsed = decodeQuery([]AppImage, allocator, output, false) catch |err| {
        allocator.free(output);
        return err;
    };
    defer parsed.deinit();

    allocator.free(output);

    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
    try std.testing.expectEqualStrings("Blender", parsed.value[0].Name);
    try std.testing.expectEqual(@as(i64, 268435456), parsed.value[0].SizeOnDisk);
    try std.testing.expectEqual(UpdateType.GitHub, parsed.value[0].UpdateType);
    try std.testing.expectEqualStrings("seafoam-labs", parsed.value[0].RepoOwner.?);
    try std.testing.expect(parsed.value[0].CommandLineArgs == null);

    try std.testing.expectEqualStrings("Nightly Editor", parsed.value[1].Name);
    try std.testing.expectEqual(UpdateType.Zsync, parsed.value[1].UpdateType);
    try std.testing.expectEqualStrings("Zsync", parsed.value[1].UpdateType.toCliString());
    try std.testing.expectEqualStrings("zsync|https://nightly.example.dev/latest/Editor.AppImage.zsync", parsed.value[1].UpdateURl);
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

test "AUR queries override the source without changing shared CLI settings" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    for ([_]bool{ false, true }) |atoll| {
        const url = @import("../models/settings.zig").aurUrl(atoll);
        const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = std.testing.io, .binary = "/bin/sh", .environment = &env, .aur_url = url };
        const result = try cli.run(&.{ "-c", "printf '%s\\n' \"$@\"", "fixture" });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "--aur-url\n{s}\n--ui-mode\n", .{url});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result.stdout);
    }
}

fn checkConfigurationResult(allocator: std.mem.Allocator, output: []const u8) !void {
    var completed = false;
    var frames = JsonPackFrame.frames(output);
    while (frames.next()) |payload| {
        const json = try JsonPackFrame.decodeBase64(allocator, payload);
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.UnexpectedFrame;
        const kind = parsed.value.object.get("$kind") orelse return error.UnexpectedFrame;
        if (kind != .string) return error.UnexpectedFrame;
        if (std.mem.eql(u8, kind.string, "alpm.error")) return error.CommandFailed;
        if (!std.mem.eql(u8, kind.string, "alpm.info")) return error.UnsupportedFrame;
        const event = parsed.value.object.get("EventType") orelse return error.UnexpectedFrame;
        if (event != .string) return error.UnexpectedFrame;
        if (std.mem.eql(u8, event.string, "TransactionFailed") or std.mem.eql(u8, event.string, "TransactionCancelled")) return error.CommandFailed;
        if (std.mem.eql(u8, event.string, "TransactionDone")) completed = true;
    }
    if (!completed) return error.MissingCompletion;
}

test "AppImage configuration requires confirmed completion and rejects reported failures" {
    const allocator = std.testing.allocator;
    const done = try queryTestFrame(allocator, "{\"$kind\":\"alpm.info\",\"EventType\":\"TransactionDone\"}");
    defer allocator.free(done);
    try checkConfigurationResult(allocator, done);
    const failure = try queryTestFrame(allocator, "{\"$kind\":\"alpm.error\",\"ErrorMessage\":\"Invalid source\"}");
    defer allocator.free(failure);
    const output = try std.mem.concat(allocator, u8, &.{ done, failure });
    defer allocator.free(output);
    try std.testing.expectError(error.CommandFailed, checkConfigurationResult(allocator, output));
    try std.testing.expectError(error.MissingCompletion, checkConfigurationResult(allocator, ""));
}

test "independent update checks overlap native checks and respect source selection" {
    const allocator = std.testing.allocator;
    const frame = try queryTestFrame(allocator, "[]");
    defer allocator.free(frame);
    const app_frame = try queryTestFrame(allocator, "[{\"Name\":\"Editor\",\"Version\":\"2\",\"DownloadUrl\":\"https://example.org/app.AppImage\",\"IsUpdateAvailable\":true}]");
    defer allocator.free(app_frame);
    const Case = struct { appimage: bool, fail_native: bool = false, fail_appimage: bool = false };
    for ([_]Case{ .{ .appimage = false }, .{ .appimage = true }, .{ .appimage = true, .fail_native = true }, .{ .appimage = true, .fail_appimage = true } }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fixture", .flags = .{ .permissions = .executable_file }, .data =
            \\#!/bin/sh
            \\cd "$FIXTURE_DIR" || exit 1
            \\case "$2" in
            \\  appimage) [ "$EXPECT_APPIMAGE" = 1 ] || exit 1; : > appimage; [ "$FAIL_APPIMAGE" = 1 ] && exit 1; printf '%s' "$APP_FRAME"; exit 0 ;;
            \\  flatpak) : > flatpak; other=native ;;
            \\  standard) : > native; other=flatpak ;;
            \\  *) exit 1 ;;
            \\esac
            \\attempt=0
            \\while [ ! -f "$other" ] || { [ "$EXPECT_APPIMAGE" = 1 ] && [ ! -f appimage ]; }; do
            \\  attempt=$((attempt + 1))
            \\  [ "$attempt" -lt 200 ] || exit 1
            \\  /bin/sleep 0.01
            \\done
            \\if [ "$2" = standard ] && [ "$FAIL_NATIVE" = 1 ]; then exit 1; fi
            \\printf '%s' "$FRAME"
        });
        const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(directory);
        const binary = try std.fs.path.join(allocator, &.{ directory, "fixture" });
        defer allocator.free(binary);
        var env: std.process.Environ.Map = .init(allocator);
        defer env.deinit();
        try env.put("FIXTURE_DIR", directory);
        try env.put("FAIL_NATIVE", if (case.fail_native) "1" else "0");
        try env.put("FRAME", frame);
        try env.put("APP_FRAME", app_frame);
        try env.put("EXPECT_APPIMAGE", if (case.appimage) "1" else "0");
        try env.put("FAIL_APPIMAGE", if (case.fail_appimage) "1" else "0");
        const cli: ShellyCli = .{ .allocator = allocator, .io = std.testing.io, .binary = binary, .environment = &env };
        if (case.fail_native or case.fail_appimage) {
            try std.testing.expectError(error.CommandFailed, cli.check_updates_for_sources(false, true, case.appimage));
        } else {
            const parsed = try cli.check_updates_for_sources(false, true, case.appimage);
            defer parsed.deinit();
            try std.testing.expectEqual(@as(usize, @intFromBool(case.appimage)), parsed.value.count());
            if (case.appimage) try std.testing.expectEqualStrings("Editor", parsed.value.AppImage[0].Name);
        }
    }
}

fn UpdateQuery(comptime T: type, comptime source: []const u8) type {
    return struct {
        cli: ShellyCli,
        result: ?std.json.Parsed([]T) = null,
        failure: ?anyerror = null,
        thread: ?std.Thread = null,

        fn start(self: *@This()) !void {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        fn run(self: *@This()) void {
            var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            var cli = self.cli;
            cli.allocator = std.heap.page_allocator;
            cli.io = threaded.io();
            self.result = cli.sourceUpdates(T, source) catch |err| {
                self.failure = err;
                return;
            };
        }

        fn join(self: *@This()) void {
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }

        fn deinit(self: *@This()) void {
            self.join();
            if (self.result) |parsed| parsed.deinit();
        }
    };
}
