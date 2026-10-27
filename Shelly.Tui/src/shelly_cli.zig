const std = @import("std");
const diagnostics = @import("diagnostics");
const Io = std.Io;
const Package = @import("packages.zig").Package;
const AurPackage = @import("packages.zig").AurPackage;
const PkgBuild = @import("pkgbuild.zig").PkgBuild;
const Remote = @import("flatpak.zig").Remote;
const Flatpak = @import("flatpak.zig").Flatpak;
const AppImage = @import("appimage.zig").AppImage;
const AppImageUpdate = @import("appimage.zig").AppImageUpdate;
const AppstreamApp = @import("flatpak.zig").AppstreamApp;
const FlatpakSearchResponse = @import("flatpak.zig").FlatpakSearchResponse;
const CheckUpdates = @import("sync.zig").CheckUpdates;
const JsonPackFrame = @import("ui_decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const log = std.log.scoped(.shelly_cli);

fn containsPackageName(packages: []const Package, name: []const u8) bool {
    for (packages) |pkg| {
        if (std.mem.eql(u8, pkg.Name, name)) return true;
    }
    return false;
}

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

pub const ShellyCli = struct {
    allocator: std.mem.Allocator,
    io: Io,

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        return self.runInner(args, false);
    }

    /// Mutating operations report failures silently because debug output
    /// would corrupt the alternate screen. `std.process.run` already gives
    /// the child an ignored stdin, so an unexpected prompt fails fast
    /// instead of hanging the TUI.
    fn runSilently(self: ShellyCli, args: []const []const u8) !RunResult {
        return self.runInner(args, true);
    }

    fn runInner(self: ShellyCli, args: []const []const u8, comptime silent: bool) !RunResult {
        const shelly_bin = if (builtin.mode == .Debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";

        var argv = try self.allocator.alloc([]const u8, args.len + 2);
        defer self.allocator.free(argv);
        argv[0] = shelly_bin;
        @memcpy(argv[1 .. 1 + args.len], args);
        argv[argv.len - 1] = "--ui-mode";

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = runtime.environ_map,
        });
        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            if (!silent) {
                std.debug.print("The Shelly command did not complete successfully.\n\nTechnical details: {0any}; {1f}; {2f}\n", .{ result.term, diagnostics.safe(result.stderr), diagnostics.safe(result.stdout[0..@min(500, result.stdout.len)]) });
            }
            return error.CommandFailed;
        }

        return result;
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

    pub fn isPackageInstalled(self: ShellyCli, name: []const u8) !bool {
        const result = try self.run(&.{ "-Ssi", name });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const parsed = try decodeQuery([]Package, self.allocator, result.stdout, true);
        defer parsed.deinit();

        return containsPackageName(parsed.value, name);
    }

    pub fn get_remotes(self: ShellyCli) !std.json.Parsed([]Remote) {
        const result = try self.run(&.{ "list", "flatpak", "remote" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]Remote, self.allocator, result.stdout, false);
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

    pub fn get_flatpak_remote_info(self: ShellyCli, id: []const u8) !std.json.Parsed(FlatpakSearchResponse) {
        const result = try self.run(&.{ "search", "flatpak", id });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery(FlatpakSearchResponse, self.allocator, result.stdout, false);
    }

    pub fn get_package_details(self: ShellyCli, name: []const u8) !std.json.Parsed(Package) {
        const result = try self.run(&.{ "search", "standard", name, "--detail", "--installed" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return decodeQuery(Package, self.allocator, result.stdout, false);
    }

    /// Searches system packages via the CLI. The caller owns the parsed result.
    pub fn search_standard(self: ShellyCli, query: []const u8) !std.json.Parsed([]Package) {
        const result = try self.run(&.{
            "search", "standard", "--available", "--installed", query,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]Package, self.allocator, result.stdout, true);
    }

    /// Searches the AUR via the CLI. The caller owns the parsed result.
    pub fn search_aur(self: ShellyCli, query: []const u8) !std.json.Parsed([]AurPackage) {
        const result = try self.run(&.{ "search", "aur", query });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AurPackage, self.allocator, result.stdout, false);
    }

    pub fn list_aur_installed(self: ShellyCli) !std.json.Parsed([]AurPackage) {
        const result = try self.run(&.{
            "list",
            "aur",
        });
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

        log.debug("pkgbuild response received ({d} bytes)", .{result.stdout.len});

        return decodeQuery([]PkgBuild, self.allocator, result.stdout, false);
    }

    pub fn search_flatpak(self: ShellyCli, query: []const u8) !std.json.Parsed(FlatpakSearchResponse) {
        const result = try self.run(&.{ "search", "flatpak", query, "--limit", "50" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery(FlatpakSearchResponse, self.allocator, result.stdout, false);
    }

    pub fn get_appimages(self: ShellyCli) !std.json.Parsed([]AppImage) {
        const result = try self.run(&.{ "list", "appimage" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AppImage, self.allocator, result.stdout, false);
    }

    pub fn get_appimage_updates(self: ShellyCli) !std.json.Parsed([]AppImageUpdate) {
        const result = try self.run(&.{ "list-updates", "appimage" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery([]AppImageUpdate, self.allocator, result.stdout, false);
    }

    pub const InstallBackend = enum { standard, aur, flatpak, appimage };

    /// Installs a package through the CLI without prompting. Fails with
    /// error.CommandFailed when the CLI exits non-zero.
    pub fn install_package(self: ShellyCli, backend: InstallBackend, name: []const u8) !void {
        const result = try self.runSilently(&.{ "install", @tagName(backend), name, "--no-confirm" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    pub fn check_updates(self: ShellyCli, show_hidden: bool) !std.json.Parsed(CheckUpdates) {
        const result = try self.run(if (show_hidden) &.{ "-P", "--show-hidden" } else &.{"-P"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return decodeQuery(CheckUpdates, self.allocator, result.stdout, false);
    }
};

test "get_packages" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_packages(false);

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {s}\n", .{ parsed.value[0].Name, parsed.value[0].Version });
}

test "get_remotes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_remotes();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {t}\n", .{ parsed.value[0].Name, parsed.value[0].Scope });
}

test "get_flatpaks" {
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
    try std.testing.expect(containsPackageName(parsed.value, "editor"));
    try std.testing.expect(!containsPackageName(parsed.value, "edit"));
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
