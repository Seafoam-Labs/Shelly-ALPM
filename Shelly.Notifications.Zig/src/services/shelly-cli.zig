const std = @import("std");
const Io = std.Io;
const JsonPackFrame = @import("ui-mode-decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;
const CheckUpdates = @import("../models/update.zig").CheckUpdates;
const runtime = @import("../runtime.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.cli);

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
    environ_map: *std.process.Environ.Map,

    fn exec(self: ShellyCli, argv: []const []const u8) !RunResult {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = self.environ_map,
        }) catch |err| {
            const message = try @import("diagnostics").format(self.allocator, err, .{ .operation = "the Shelly command", .path = argv[0] });
            defer self.allocator.free(message);
            log.err("{s}", .{message});
            return err;
        };

        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            const structured = try JsonPackFrame.failureMessage(self.allocator, result.stdout);
            defer if (structured) |message| self.allocator.free(message);
            const message = try @import("diagnostics").sanitizeAlloc(self.allocator, structured orelse
                if (result.stderr.len > 0) result.stderr else "Shelly returned no error details. Review the command output before retrying.");
            defer self.allocator.free(message);
            log.err("Could not run {f}. {s}\nProcess result: {any}", .{
                @import("diagnostics").safe(argv[0]), message, result.term,
            });
            return error.CommandFailed;
        }

        return result;
    }

    pub fn check_updates(self: ShellyCli) !std.json.Parsed(CheckUpdates) {
        const result = try self.exec(&.{ "shelly", "-P", "--ui-mode" });
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

test "get_updates" {
    if (true) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/usr/local/bin:/bin");
    try env.put("HOME", "/home/caro");

    const cli = ShellyCli{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
        .environ_map = &env,
    };
    const parsed = try cli.check_updates();
    defer parsed.deinit();
    try std.testing.expect(parsed.value.Packages.len > 0);
}
