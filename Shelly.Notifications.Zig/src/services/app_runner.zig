const std = @import("std");
const diagnostics = @import("diagnostics");

const conch = @import("zsn");
const Service = conch.Service;
const wakeWorker = @import("../main.zig").wakeWorker;
const runtime = @import("../runtime.zig");
const Config = @import("../models/shelly_config.zig").ShellyConfig;

const log = std.log.scoped(.runner);

pub const AppRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,

    activation_token: ?[:0]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
    ) AppRunner {
        return .{ .allocator = allocator, .io = io, .environ_map = environ_map };
    }

    pub fn setActivationToken(self: *AppRunner, token: []const u8) !void {
        if (self.activation_token) |old| self.allocator.free(old);
        self.activation_token = try self.allocator.dupeSentinel(u8, token, 0);
    }

    pub fn takeActivationToken(self: *AppRunner) ?[]const u8 {
        const t = self.activation_token;
        self.activation_token = null;
        return t;
    }

    pub fn deinit(self: *AppRunner) void {
        if (self.activation_token) |t| self.allocator.free(t);
    }

    /// Candidate terminals probed in order when nothing is configured.
    /// Keep in sync with `known_terminals` in Shelly.Ui.Gtk settings_page.zig.
    const terminal_candidates = [_][]const u8{
        "alacritty",  "rio",   "ghostty",        "kitty",
        "konsole",    "kgx",   "gnome-terminal", "xfce4-terminal",
        "lxterminal", "xterm", "st",             "foot",
        "terminator",
    };

    /// Terminals that take the command after `--` instead of `-e`.
    const dashdash_terminals = [_][]const u8{ "gnome-terminal", "kgx" };

    pub fn isCommandAvailable(self: *AppRunner, cmd: []const u8) bool {
        if (std.fs.path.isAbsolute(cmd)) {
            return self.isExecutable(cmd);
        }
        const path_env = self.environ_map.get("PATH") orelse "/usr/bin:/bin";
        var it = std.mem.tokenizeScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, cmd }) catch continue;
            if (self.isExecutable(full)) return true;
        }
        return false;
    }

    fn isExecutable(self: *AppRunner, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io, path, .{ .execute = true }) catch return false;
        return true;
    }

    /// The checker resolveTerminal asks about candidate availability, without
    /// forcing tests to build a whole AppRunner.
    const Availability = struct {
        runner: *AppRunner,

        fn isAvailable(self: Availability, cmd: []const u8) bool {
            return self.runner.isCommandAvailable(cmd);
        }
    };

    /// Where the terminal resolveTerminal picked came from, so the caller can
    /// log why an explicit setting was not honored.
    const TerminalSource = enum {
        /// The terminal selected in Settings, and found.
        configured,
        environment,
        auto_detect,
        /// Nothing else was available, so the configured terminal is tried
        /// even though it could not be found.
        configured_fallback,
    };

    const TerminalResolution = struct {
        terminal: []const u8,
        source: TerminalSource,
    };

    /// Picks the terminal for the update shell: the terminal selected in
    /// Settings first, then $TERMINAL, then the candidate list. A selected
    /// terminal that is not installed is only a preference, so resolution
    /// quietly falls back to auto-detection; if nothing else is found it is
    /// still returned last, because an explicit choice beats giving up.
    fn resolveTerminal(
        configured: []const u8,
        env_terminal: ?[]const u8,
        availability: anytype,
    ) ?TerminalResolution {
        if (configured.len > 0 and availability.isAvailable(configured)) {
            return .{ .terminal = configured, .source = .configured };
        }
        if (env_terminal) |t| {
            if (t.len > 0 and availability.isAvailable(t)) {
                return .{ .terminal = t, .source = .environment };
            }
        }
        for (terminal_candidates) |cand| {
            if (availability.isAvailable(cand)) {
                return .{ .terminal = cand, .source = .auto_detect };
            }
        }
        if (configured.len > 0) {
            return .{ .terminal = configured, .source = .configured_fallback };
        }
        return null;
    }

    /// True for terminals taking the command after `--` rather than `-e`.
    /// An absolute configured path is matched on its file name.
    fn usesDashdash(terminal: []const u8) bool {
        const name = std.fs.path.basename(terminal);
        for (dashdash_terminals) |t| {
            if (std.mem.eql(u8, name, t)) return true;
        }
        return false;
    }

    pub fn spawnFixedUpdate(self: *AppRunner, config: *const Config) !void {
        std.log.debug("spawnFixedUpdate: UseUiForUpdate={}", .{config.UseUiForUpdate});
        if (config.UseUiForUpdate) {
            try self.spawnWithToken(&.{"--tray-updates"});
            return;
        }

        const bash_cmd = "shelly; echo; read -rp 'Press Enter to close...'";

        const resolution = resolveTerminal(
            config.TerminalForUpdate,
            self.environ_map.get("TERMINAL"),
            Availability{ .runner = self },
        ) orelse {
            log.warn(
                "Could not start the update command because no supported terminal emulator was found. Select a terminal in Settings, set TERMINAL to an installed terminal, or install a supported terminal emulator.\n\nTechnical details: {0d}",
                .{terminal_candidates.len},
            );
            return error.NoTerminal;
        };
        const terminal = resolution.terminal;
        if (config.TerminalForUpdate.len > 0 and resolution.source != .configured) {
            switch (resolution.source) {
                .configured => unreachable,
                .configured_fallback => log.warn(
                    "The terminal selected in Settings was not found and no other supported terminal is installed, so '{0f}' will be tried anyway.",
                    .{diagnostics.safe(terminal)},
                ),
                else => log.warn(
                    "The terminal selected in Settings was not found, so the update shell fell back to '{0f}'.",
                    .{diagnostics.safe(terminal)},
                ),
            }
        }
        log.info("launching update shell in '{s}' ({s})", .{ terminal, @tagName(resolution.source) });

        const argv: []const []const u8 = if (usesDashdash(terminal))
            &.{ "setsid", terminal, "--", "bash", "-c", bash_cmd }
        else
            &.{ "setsid", terminal, "-e", "bash", "-c", bash_cmd };

        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.environ_map,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| {
            log.err("Could not open terminal {0f} to run updates. {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(terminal), diagnostics.cause(e), @errorName(e) });
            return e;
        };

        _ = child.wait(runtime.io) catch |e| {
            log.warn("Could not collect the result of the update terminal. {0s} The update status could not be confirmed.\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
        };
        log.info("update finished, terminal closed", .{});

        runtime.wakeWorker();
    }

    pub fn activateOrLaunch(self: *AppRunner, service: *Service) !void {
        service.activateApplication(
            "com.shellyorg.shelly",
            "/com/shellyorg/shelly",
            self.activation_token,
        ) catch |e| {
            log.warn("Could not activate the existing Shelly window. {0s} Attempting to start shelly-ui directly.\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
            try self.spawnWithToken(&.{});
            return;
        };
        log.info("activated existing shelly-ui window", .{});
    }

    fn spawnWithToken(self: *AppRunner, extra_args: []const []const u8) !void {
        const bin = self.shellyUiBin();
        if (!self.isCommandAvailable(bin)) {
            log.err("Could not open Shelly because {0f} was not found on PATH. Check that shelly-ui is installed and accessible.", .{diagnostics.safe(bin)});
            return error.ShellyUiNotFound;
        }

        var argv_buf: std.ArrayList([]const u8) = .empty;
        defer argv_buf.deinit(self.allocator);
        try argv_buf.appendSlice(self.allocator, &.{ "setsid", bin });
        try argv_buf.appendSlice(self.allocator, extra_args);
        const argv = argv_buf.items;

        var owned_env: ?std.process.Environ.Map = if (self.activation_token) |token| blk: {
            var env = try self.environ_map.clone(self.allocator);
            errdefer env.deinit();
            try env.put("XDG_ACTIVATION_TOKEN", token);
            break :blk env;
        } else null;
        defer if (owned_env) |*e| e.deinit();
        const env_ptr: *std.process.Environ.Map = if (owned_env) |*e| e else self.environ_map;

        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = env_ptr,
            .pgid = 0,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| {
            log.err("Could not start {0f}. {1s}\n\nTechnical details: {2s}", .{ diagnostics.safe(bin), diagnostics.cause(e), @errorName(e) });
            return e;
        };
        _ = child.wait(runtime.io) catch |e| {
            log.warn("Could not collect the result of the required executable. {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
        };
        log.info("spawned '{s}' (token: {s}, args: {s})", .{
            bin,
            if (self.activation_token != null) "yes" else "no",
            if (extra_args.len > 0) extra_args[extra_args.len - 1] else "none",
        });
    }

    pub fn quitUi(self: *AppRunner, service: *Service) !void {
        const pid = service.getProcessId("com.shellyorg.shelly") catch |e| {
            log.warn("Could not find the running Shelly window process. {0s}\n\nTechnical details: {1s}", .{ diagnostics.cause(e), @errorName(e) });
            return;
        };
        _ = self;
        std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch |e| {
            log.err("Could not stop Shelly window process {0d}. {1s}\n\nTechnical details: {2s}", .{ pid, diagnostics.cause(e), @errorName(e) });
            return e;
        };
        log.info("sent SIGTERM to shelly-ui (pid {d})", .{pid});
    }

    fn shellyUiBin(self: *AppRunner) []const u8 {
        _ = self;
        return "shelly-ui";
    }
};

const testing = std.testing;

/// Availability checker standing in for PATH probing: only the listed
/// commands are installed.
const FakeAvailability = struct {
    installed: []const []const u8,

    fn isAvailable(self: FakeAvailability, cmd: []const u8) bool {
        for (self.installed) |cand| {
            if (std.mem.eql(u8, cand, cmd)) return true;
        }
        return false;
    }
};

test "resolveTerminal prefers the configured terminal" {
    const resolved = AppRunner.resolveTerminal(
        "wezterm",
        "kitty",
        FakeAvailability{ .installed = &.{ "wezterm", "kitty", "alacritty" } },
    ).?;
    try testing.expectEqualStrings("wezterm", resolved.terminal);
    try testing.expectEqual(AppRunner.TerminalSource.configured, resolved.source);
}

test "resolveTerminal falls back when the configured terminal is missing" {
    const resolved = AppRunner.resolveTerminal(
        "wezterm",
        "kitty",
        FakeAvailability{ .installed = &.{ "kitty", "alacritty" } },
    ).?;
    try testing.expectEqualStrings("kitty", resolved.terminal);
    try testing.expectEqual(AppRunner.TerminalSource.environment, resolved.source);
}

test "resolveTerminal keeps the configured terminal as the last resort" {
    const resolved = AppRunner.resolveTerminal(
        "wezterm",
        "gnome-terminal",
        FakeAvailability{ .installed = &.{} },
    ).?;
    try testing.expectEqualStrings("wezterm", resolved.terminal);
    try testing.expectEqual(AppRunner.TerminalSource.configured_fallback, resolved.source);
}

test "resolveTerminal without a configured terminal keeps the old behavior" {
    const environment = AppRunner.resolveTerminal(
        "",
        "foot",
        FakeAvailability{ .installed = &.{ "foot", "alacritty" } },
    ).?;
    try testing.expectEqualStrings("foot", environment.terminal);
    try testing.expectEqual(AppRunner.TerminalSource.environment, environment.source);

    const auto = AppRunner.resolveTerminal(
        "",
        "missing-term",
        FakeAvailability{ .installed = &.{"xterm"} },
    ).?;
    try testing.expectEqualStrings("xterm", auto.terminal);
    try testing.expectEqual(AppRunner.TerminalSource.auto_detect, auto.source);

    try testing.expectEqual(@as(?AppRunner.TerminalResolution, null), AppRunner.resolveTerminal(
        "",
        null,
        FakeAvailability{ .installed = &.{} },
    ));
}

test "usesDashdash matches configured paths on their file name" {
    try testing.expect(AppRunner.usesDashdash("gnome-terminal"));
    try testing.expect(AppRunner.usesDashdash("/usr/bin/kgx"));
    try testing.expect(!AppRunner.usesDashdash("alacritty"));
    try testing.expect(!AppRunner.usesDashdash("/opt/wezterm/bin/wezterm"));
}
