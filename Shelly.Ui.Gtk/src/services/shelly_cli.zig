const std = @import("std");
const Io = std.Io;
const Package = @import("../models/packages.zig").Package;
const Remote = @import("../models/flatpak.zig").Remote;
const Flatpak = @import("../models/flatpak.zig").Flatpak;
const AppstreamApp = @import("../models/flatpak.zig").AppstreamApp;
const FlatpakSearchResponse = @import("../models/flatpak.zig").FlatpakSearchResponse;
const CheckUpdates = @import("../models/sync.zig").CheckUpdates;
const AppImage = @import("../models/appimage.zig").AppImage;
const AppImageUpdate = @import("../models/appimage.zig").AppImageUpdate;
const JsonPackFrame = @import("../helpers/ui_decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;
const AurPackage = @import("../models/aur_package.zig").AurPackage;
const PkgBuild = @import("../models/pkgbuild.zig").PkgBuild;
const runtime = @import("runtime.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.shelly_cli);

pub const CliMessage = struct {
    @"$kind": []const u8 = "",
    Message: []const u8 = "",
    ErrorMessage: []const u8 = "",
    Level: []const u8 = "",

    pub fn isSuccess(self: *const CliMessage) bool {
        return self.ErrorMessage.len == 0;
    }

    pub fn text(self: *const CliMessage) []const u8 {
        if (self.ErrorMessage.len > 0) return self.ErrorMessage;
        return self.Message;
    }
};

fn containsPackageName(packages: []const Package, name: []const u8) bool {
    for (packages) |pkg| {
        if (std.mem.eql(u8, pkg.Name, name)) return true;
    }
    return false;
}

pub const ShellyCli = struct {
    /// Optional explanation for a failed subprocess. Initialize to null;
    /// the caller owns the returned slice using this client's allocator.
    failure_detail: ?*?[]u8 = null,
    allocator: std.mem.Allocator,
    io: Io,

    fn shellyBin() []const u8 {
        return if (builtin.mode == .Debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";
    }

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        return self.runWith(args, false);
    }

    fn runPrivileged(self: ShellyCli, args: []const []const u8) !RunResult {
        return self.runWith(args, true);
    }

    fn runWith(self: ShellyCli, args: []const []const u8, privileged: bool) !RunResult {
        const argv = try self.buildArgv(args, privileged);
        defer self.allocator.free(argv);
        return try self.exec(argv);
    }

    fn buildArgv(self: ShellyCli, args: []const []const u8, privileged: bool) ![]const []const u8 {
        const extra: usize = if (privileged) 3 else 2;
        var argv = try self.allocator.alloc([]const u8, args.len + extra);

        var i: usize = 0;
        if (privileged) {
            argv[i] = "pkexec";
            i += 1;
        }

        argv[i] = shellyBin();
        i += 1;

        @memcpy(argv[i .. i + args.len], args);
        i += args.len;

        argv[i] = "--ui-mode";
        return argv;
    }

    fn exec(self: ShellyCli, argv: []const []const u8) !RunResult {
        if (builtin.mode == .Debug) {
            if (std.mem.join(self.allocator, " ", argv)) |command| {
                defer self.allocator.free(command);
                log.debug("argv: {s}", .{command});
            } else |_| {
                log.debug("argv: {d} arguments", .{argv.len});
            }
        }

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = runtime.environ_map,
        });

        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            log.err("command failed: term={any} stderr='{s}' stdout='{s}'", .{
                result.term,
                result.stderr[0..@min(500, result.stderr.len)],
                result.stdout[0..@min(500, result.stdout.len)],
            });
            if (self.failure_detail) |detail| {
                detail.* = try JsonPackFrame.failureMessage(self.allocator, result.stdout) orelse
                    try self.allocator.dupe(u8, if (result.stderr.len > 0) result.stderr else "Could not complete the package operation. No error details were returned by Shelly.");
            }
            return error.CommandFailed;
        }

        return result;
    }

    pub fn repair_db(self: ShellyCli) !std.json.Parsed(CliMessage) {
        const result = try self.runPrivileged(&.{ "utility", "--repair-db" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode(CliMessage, self.allocator, result.stdout);
    }

    pub fn get_packages(self: ShellyCli, show_hidden: bool) !std.json.Parsed([]Package) {
        const result = try self.run(&.{if (show_hidden) "-Ssvw" else "-Ssv"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Package, self.allocator, result.stdout);
    }

    pub fn get_installed_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{"-Ls"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Package, self.allocator, result.stdout);
    }

    pub fn isPackageInstalled(self: ShellyCli, name: []const u8) !bool {
        const result = try self.run(&.{ "-Ssi", name });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const parsed = JsonPackFrame.decode([]Package, self.allocator, result.stdout) catch return false;
        defer parsed.deinit();

        return containsPackageName(parsed.value, name);
    }

    pub fn getRemotes(self: ShellyCli) !std.json.Parsed([]Remote) {
        const result = try self.run(&.{ "list", "flatpak", "remote" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Remote, self.allocator, result.stdout);
    }

    pub fn getInstalledFlatpaks(self: ShellyCli) !std.json.Parsed([]Flatpak) {
        const result = try self.run(&.{"-Lf"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Flatpak, self.allocator, result.stdout);
    }

    pub fn getRemoteAppstreamApps(self: ShellyCli) !std.json.Parsed([]AppstreamApp) {
        const result = try self.run(&.{ "list", "flatpak", "remote", "all" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]AppstreamApp, self.allocator, result.stdout);
    }

    pub fn get_flatpak_remote_info(self: ShellyCli, id: []const u8) !std.json.Parsed(FlatpakSearchResponse) {
        const result = try self.run(&.{ "search", "flatpak", id });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode(FlatpakSearchResponse, self.allocator, result.stdout);
    }

    pub fn get_package_details(self: ShellyCli, name: []const u8) !std.json.Parsed(Package) {
        const result = try self.run(&.{ "search", "standard", name });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return JsonPackFrame.decodeLast(Package, self.allocator, result.stdout);
    }

    pub fn search_aur(self: ShellyCli, query: []const u8) !std.json.Parsed([]AurPackage) {
        const result = try self.run(&.{ "search", "aur", query });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return JsonPackFrame.decodeLast([]AurPackage, self.allocator, result.stdout);
    }

    const StandardSearchWrapper = struct {
        Packages: []Package = &.{},
    };

    pub fn search_standard(self: ShellyCli, query: []const u8) !std.json.Parsed([]Package) {
        const result = try self.run(&.{ "search", "standard", "--available", "--installed", query });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var it = JsonPackFrame.frames(result.stdout);
        while (it.next()) |payload| {
            const json = JsonPackFrame.decodeBase64(self.allocator, payload) catch continue;
            defer self.allocator.free(json);

            if (std.mem.indexOf(u8, json, "\"$kind\"") != null) continue;

            const options = std.json.ParseOptions{ .ignore_unknown_fields = true, .allocate = .alloc_always };
            const trimmed = std.mem.trim(u8, json, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "[")) {
                return std.json.parseFromSlice([]Package, self.allocator, json, options);
            }

            const wrapper = try std.json.parseFromSlice(StandardSearchWrapper, self.allocator, json, options);
            return .{ .arena = wrapper.arena, .value = wrapper.value.Packages };
        }

        return error.NoDataFrame;
    }

    pub fn search_flatpak(self: ShellyCli, query: []const u8) !std.json.Parsed(FlatpakSearchResponse) {
        const result = try self.run(&.{ "search", "flatpak", query, "--limit", "50" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var it = JsonPackFrame.frames(result.stdout);
        while (it.next()) |payload| {
            const json = JsonPackFrame.decodeBase64(self.allocator, payload) catch continue;
            defer self.allocator.free(json);

            if (std.mem.indexOf(u8, json, "\"$kind\"") != null) continue;

            return std.json.parseFromSlice(FlatpakSearchResponse, self.allocator, json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        }

        return error.NoDataFrame;
    }

    pub fn list_aur_installed(self: ShellyCli) !std.json.Parsed([]AurPackage) {
        const result = try self.run(&.{
            "list",
            "aur",
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return JsonPackFrame.decodeLast([]AurPackage, self.allocator, result.stdout);
    }

    pub fn get_appimages(self: ShellyCli) !std.json.Parsed([]AppImage) {
        const result = try self.run(&.{ "list", "appimage" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return JsonPackFrame.decode([]AppImage, self.allocator, result.stdout);
    }

    pub fn get_appimage_updates(self: ShellyCli) !std.json.Parsed([]AppImageUpdate) {
        const result = try self.run(&.{ "list-updates", "appimage" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return JsonPackFrame.decode([]AppImageUpdate, self.allocator, result.stdout);
    }

    pub fn sync_remote_appstream_flatpak(self: ShellyCli) !void {
        const result = try self.run(&.{
            "sync",
            "flatpak",
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    pub fn check_updates(self: ShellyCli) !std.json.Parsed(CheckUpdates) {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "-P");

        if (runtime.config) |cfg_service| {
            if (cfg_service.get()) |cfg| {
                if (cfg.AurUpdateShowHidden) {
                    try argv.append(self.allocator, "--show-hidden");
                }
            } else |_| {}
        }

        const result = try self.run(argv.items);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var it = JsonPackFrame.frames(result.stdout);
        while (it.next()) |payload| {
            const json = JsonPackFrame.decodeBase64(self.allocator, payload) catch continue;
            defer self.allocator.free(json);

            if (std.mem.indexOf(u8, json, "\"$kind\"") != null) continue;

            return std.json.parseFromSlice(CheckUpdates, self.allocator, json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        }

        return error.NoDataFrame;
    }

    pub fn fetch_pkgbuild(self: ShellyCli, name: []const u8) !std.json.Parsed([]PkgBuild) {
        const result = try self.run(&.{ "search", "aur", name, "--pkgbuild" });
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);

        if (result.stderr.len > 0) return error.FetchPkgbuildFailed;

        log.debug("pkgbuild response received ({d} bytes)", .{result.stdout.len});

        return JsonPackFrame.decode([]PkgBuild, self.allocator, result.stdout);
    }
};

test "get_packages" {
    if (true) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_packages(false);

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {s}\n", .{ parsed.value[0].Name, parsed.value[0].Version });
}

test "get_remotes" {
    if (true) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_remotes();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {t}\n", .{ parsed.value[0].Name, parsed.value[0].Scope });
}

test "get_flatpaks" {
    if (true) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_installed_flatpaks();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {t}\n", .{ parsed.value[0].Name, parsed.value[0].InstallLevel });
}

test "installed lookup only accepts an exact package name" {
    const packages = [_]Package{
        .{ .Name = "noctalia", .Repository = "local" },
        .{ .Name = "aqueous-configs", .Repository = "local" },
    };

    try std.testing.expect(containsPackageName(&packages, "noctalia"));
    try std.testing.expect(!containsPackageName(&packages, "noct"));
    try std.testing.expect(!containsPackageName(&packages, "flatpak"));
    try std.testing.expect(!containsPackageName(&[_]Package{}, "fuse2"));
}
