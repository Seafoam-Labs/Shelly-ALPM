const std = @import("std");
const Io = std.Io;
const Package = @import("packages.zig").Package;
const AurPackage = @import("packages.zig").AurPackage;
const Remote = @import("flatpak.zig").Remote;
const Flatpak = @import("flatpak.zig").Flatpak;
const AppstreamApp = @import("flatpak.zig").AppstreamApp;
const FlatpakSearchResponse = @import("flatpak.zig").FlatpakSearchResponse;
const CheckUpdates = @import("sync.zig").CheckUpdates;
const JsonPackFrame = @import("ui_decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;
const runtime = @import("runtime.zig");
const builtin = @import("builtin");

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
                std.debug.print("failed: term={any} stderr='{s}' stdout='{s}'\n", .{
                    result.term, result.stderr, result.stdout[0..@min(500, result.stdout.len)],
                });
            }
            return error.CommandFailed;
        }

        return result;
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
        const result = try self.run(&.{ "flatpak", "list", "remote" });
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

    /// Searches the AUR via the CLI. The caller owns the parsed result.
    pub fn search_aur(self: ShellyCli, query: []const u8) !std.json.Parsed([]AurPackage) {
        const result = try self.run(&.{ "search", "aur", query });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var it = JsonPackFrame.frames(result.stdout);
        while (it.next()) |payload| {
            const json = try JsonPackFrame.decodeBase64(self.allocator, payload);
            defer self.allocator.free(json);
            // Skip info/error frames, decode the first data frame
            if (std.mem.indexOf(u8, json, "\"$kind\"") != null) continue;
            return std.json.parseFromSlice([]AurPackage, self.allocator, json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        }
        return error.NoDataFrame;
    }

    pub const InstallBackend = enum { standard, aur };

    /// Installs a package through the CLI without prompting. Fails with
    /// error.CommandFailed when the CLI exits non-zero.
    pub fn install_package(self: ShellyCli, backend: InstallBackend, name: []const u8) !void {
        const result = try self.runSilently(&.{ "install", @tagName(backend), name, "--no-confirm" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
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
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_packages();

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
