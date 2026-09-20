const std = @import("std");

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
        self.activation_token = try self.allocator.dupeZ(u8, token);
    }

    pub fn takeActivationToken(self: *AppRunner) ?[]const u8 {
        const t = self.activation_token;
        self.activation_token = null;
        return t;
    }

    pub fn deinit(self: *AppRunner) void {
        if (self.activation_token) |t| self.allocator.free(t);
    }

    const terminal_candidates = [_][]const u8{
        "alacritty",  "rio",   "ghostty",        "kitty",
        "konsole",    "kgx",   "gnome-terminal", "xfce4-terminal",
        "lxterminal", "xterm", "st",             "foot",
        "terminator",
    };

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

    fn findTerminalNoAlloc(self: *AppRunner) ?[]const u8 {
        if (self.environ_map.get("TERMINAL")) |t| {
            if (t.len > 0 and self.isCommandAvailable(t)) return t;
        }

        for (terminal_candidates) |cand| {
            if (self.isCommandAvailable(cand)) return cand;
        }
        return null;
    }

    pub fn spawnFixedUpdate(self: *AppRunner, config: *const Config) !void {
        std.log.debug("spawnFixedUpdate: UseUiForUpdate={}", .{config.UseUiForUpdate});
        if (config.UseUiForUpdate) {
            try self.spawnWithToken(&.{"--tray-updates"});
            return;
        }

        const bash_cmd = "shelly; echo; read -rp 'Press Enter to close...'";

        const terminal = self.findTerminalNoAlloc() orelse {
            log.warn(
                "Could not start the update command because no supported terminal emulator was found. Set TERMINAL to an installed terminal or install a supported terminal emulator.\n\nTechnical details: {0d}",
                .{terminal_candidates.len},
            );
            return error.NoTerminal;
        };
        log.info("launching update shell in '{s}'", .{terminal});

        const use_dashdash = std.mem.eql(u8, terminal, "gnome-terminal") or
            std.mem.eql(u8, terminal, "kgx");

        const argv: []const []const u8 = if (use_dashdash)
            &.{ "setsid", terminal, "--", "bash", "-c", bash_cmd }
        else
            &.{ "setsid", terminal, "-e", "bash", "-c", bash_cmd };

        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.environ_map,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| {
            log.err("Could not open terminal {0f} to run updates. {1s}\n\nTechnical details: {2s}", .{ @import("diagnostics").safe(terminal), @import("diagnostics").cause(e), @errorName(e) });
            return e;
        };

        _ = child.wait(runtime.io) catch |e| {
            log.warn("Could not collect the result of the update terminal. {0s} The update status could not be confirmed.\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(e), @errorName(e) });
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
            log.warn("Could not activate the existing Shelly window. {0s} Attempting to start shelly-ui directly.\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(e), @errorName(e) });
            try self.spawnWithToken(&.{});
            return;
        };
        log.info("activated existing shelly-ui window", .{});
    }

    fn spawnWithToken(self: *AppRunner, extra_args: []const []const u8) !void {
        const bin = self.shellyUiBin();
        if (!self.isCommandAvailable(bin)) {
            log.err("Could not open Shelly because {0f} was not found on PATH. Check that shelly-ui is installed and accessible.", .{@import("diagnostics").safe(bin)});
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
            log.err("Could not start {0f}. {1s}\n\nTechnical details: {2s}", .{ @import("diagnostics").safe(bin), @import("diagnostics").cause(e), @errorName(e) });
            return e;
        };
        _ = child.wait(runtime.io) catch |e| {
            log.warn("Could not collect the result of the required executable. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(e), @errorName(e) });
        };
        log.info("spawned '{s}' (token: {s}, args: {s})", .{
            bin,
            if (self.activation_token != null) "yes" else "no",
            if (extra_args.len > 0) extra_args[extra_args.len - 1] else "none",
        });
    }

    pub fn quitUi(self: *AppRunner, service: *Service) !void {
        const pid = service.getProcessId("com.shellyorg.shelly") catch |e| {
            log.warn("Could not find the running Shelly window process. {0s}\n\nTechnical details: {1s}", .{ @import("diagnostics").cause(e), @errorName(e) });
            return;
        };
        _ = self;
        std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch |e| {
            log.err("Could not stop Shelly window process {0d}. {1s}\n\nTechnical details: {2s}", .{ pid, @import("diagnostics").cause(e), @errorName(e) });
            return e;
        };
        log.info("sent SIGTERM to shelly-ui (pid {d})", .{pid});
    }

    fn shellyUiBin(self: *AppRunner) []const u8 {
        _ = self;
        return "shelly-ui";
    }
};
