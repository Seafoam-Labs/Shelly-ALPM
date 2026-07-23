const std = @import("std");
const Io = std.Io;
const Package = @import("../models/packages.zig").Package;
const Remote = @import("../models/flatpak.zig").Remote;
const Flatpak = @import("../models/flatpak.zig").Flatpak;
const AppstreamApp = @import("../models/flatpak.zig").AppstreamApp;
const FlatpakSearchResponse = @import("../models/flatpak.zig").FlatpakSearchResponse;
const CheckUpdates = @import("../models/sync.zig").CheckUpdates;
const JsonPackFrame = @import("../helpers/ui_decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;
const runtime = @import("runtime.zig");
const builtin = @import("builtin");

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

pub const ShellyCli = struct {
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
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = runtime.environ_map,
        });

        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: term={any} stderr='{s}' stdout='{s}'\n", .{
                result.term,
                result.stderr,
                result.stdout[0..@min(500, result.stdout.len)],
            });
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

    pub fn get_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{"-Ssv"});
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

    pub fn get_remotes(self: ShellyCli) !std.json.Parsed([]Remote) {
        const result = try self.run(&.{ "list", "flatpak", "remote" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Remote, self.allocator, result.stdout);
    }

    pub fn get_installed_flatpaks(self: ShellyCli) !std.json.Parsed([]Flatpak) {
        const result = try self.run(&.{"-Lf"});
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Flatpak, self.allocator, result.stdout);
    }

    pub fn get_remote_appstream_apps(self: ShellyCli) !std.json.Parsed([]AppstreamApp) {
        const result = try self.run(&.{ "list", "flatpak", "remote", "all" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]AppstreamApp, self.allocator, result.stdout);
    }

    pub fn get_flatpak_remote_info(self: ShellyCli, remote: []const u8, id: []const u8, branch: []const u8) !std.json.Parsed(FlatpakSearchResponse) {
        const result = try self.run(&.{ "search", "flatpak", id });
        _ = remote;
        _ = branch;
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

    pub fn check_updates(self: ShellyCli) !std.json.Parsed(CheckUpdates) {
        const result = try self.run(&.{"-P"});
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
};

test "get_packages" {
    if (true) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_packages();

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
