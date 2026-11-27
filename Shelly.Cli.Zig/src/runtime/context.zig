const std = @import("std");
const diagnostics = @import("diagnostics");
const PackageManager = @import("PackageManager");
const parser = @import("../cli/parser.zig");
const log = @import("log.zig");

pub const DispatchFn = *const fn (
    user_data: ?*anyopaque,
    context: *RuntimeContext,
    invocation: *const parser.Invocation,
) anyerror!u8;

pub const Dispatcher = struct {
    user_data: ?*anyopaque = null,
    call: DispatchFn = unimplemented,
};

pub const RuntimeContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdin: ?*std.Io.Reader = null,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    environment: ?*const std.process.Environ.Map = null,
    environ: std.process.Environ = .empty,
    config_path: ?[]const u8 = null,
    stdin_is_tty: bool = false,
    stdout_is_tty: bool = false,
    dispatcher: Dispatcher = .{},
    preparation_diagnostic: ?*?PackageManager.pkgbuild.parser.Diagnostic = null,
    transaction_log: ?*log.TransactionLog = null,
    tray_refresh_requested: bool = false,

    pub fn dispatch(self: *RuntimeContext, invocation: *const parser.Invocation) !u8 {
        const previous = self.config_path;
        defer self.config_path = previous;
        if (invocation.globals.config_path) |path| {
            // Keep the selection stable across elevation and subprocess cwd changes.
            const absolute = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
            defer self.allocator.free(absolute);
            self.config_path = absolute;
            return self.dispatcher.call(self.dispatcher.user_data, self, invocation);
        }
        return self.dispatcher.call(self.dispatcher.user_data, self, invocation);
    }

    pub fn childArguments(self: *const RuntimeContext, arguments: []const []const u8) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(self.allocator);
        if (self.config_path) |path| try result.appendSlice(self.allocator, &.{ "--config", path });
        var index: usize = 0;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            if (std.mem.eql(u8, argument, "--")) {
                try result.appendSlice(self.allocator, arguments[index..]);
                break;
            }
            if (self.config_path != null) {
                if (std.mem.eql(u8, argument, "--config")) {
                    index += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, argument, "--config=")) continue;
            }
            try result.append(self.allocator, argument);
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Native key operations must use the same keyring as package transactions.
    /// Returned argument strings are owned by the supplied allocator.
    pub fn keyArguments(self: *const RuntimeContext, allocator: std.mem.Allocator, arguments: []const []const u8) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        for (arguments) |argument| try result.append(allocator, try allocator.dupe(u8, argument));
        for (arguments) |argument| {
            if (std.mem.eql(u8, argument, "--user")) return result.toOwnedSlice(allocator);
        }
        try result.appendSlice(allocator, &.{ try allocator.dupe(u8, "--gpgdir"), try self.packageKeyringDirectory(allocator) });
        return result.toOwnedSlice(allocator);
    }

    pub fn packageKeyringDirectory(self: *const RuntimeContext, allocator: std.mem.Allocator) ![]const u8 {
        const Configuration = PackageManager.Manager.configuration.Configuration;
        var config = try (if (self.config_path != null) &Configuration.parseStrict else &Configuration.parse)(
            self.allocator,
            self.io,
            self.config_path orelse PackageManager.paths.config_file,
        );
        defer config.deinitialize();
        return allocator.dupe(u8, config.gpg_directory);
    }

    pub fn attachTransactionLog(
        self: *RuntimeContext,
        operation_context: *PackageManager.OperationContext,
    ) void {
        if (self.transaction_log) |transaction_log|
            _ = transaction_log.attach(operation_context) catch return;
    }
};

pub fn unimplemented(
    _: ?*anyopaque,
    context: *RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    try context.stderr.print(
        "Command '{0f}' is not implemented in this Shelly version. See 'shelly --help' for supported commands.\n",
        .{diagnostics.safe(invocation.command.path)},
    );
    return 1;
}

test "config selection reaches dispatch and reconstructed children without leaking into later commands" {
    const t = std.testing;
    const app = @import("../cli/app.zig");
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(t.io, .{ .sub_path = "custom.conf", .data = "[options]\n" });
    const path = try temporary.dir.realPathFileAlloc(t.io, "custom.conf", t.allocator);
    defer t.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    const Capture = struct {
        expected: ?[]const u8,
        calls: usize = 0,
        fn dispatch(data: ?*anyopaque, context: *RuntimeContext, _: *const parser.Invocation) !u8 {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            if (self.expected) |expected| {
                try t.expectEqualStrings(expected, context.config_path.?);
                const args = try context.childArguments(&.{ "install", "standard", "--config=old", "--", "--config=package" });
                defer context.allocator.free(args);
                try t.expectEqualStrings("--config", args[0]);
                try t.expectEqualStrings(expected, args[1]);
                try t.expectEqualStrings("--", args[4]);
                try t.expectEqualStrings("--config=package", args[5]);
            } else try t.expect(context.config_path == null);
            return 0;
        }
    };
    var capture: Capture = .{ .expected = path };
    var context: RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = t.io,
        .stdout = &output.writer,
        .stderr = &output.writer,
        .dispatcher = .{ .user_data = &capture, .call = Capture.dispatch },
    };
    try t.expectEqual(@as(u8, 0), try app.run(&context, &.{ "--config", path, "-Ss", "test" }));
    try t.expect(context.config_path == null);
    capture.expected = null;
    try t.expectEqual(@as(u8, 0), try app.run(&context, &.{ "search", "standard", "test" }));
    try t.expectEqual(@as(usize, 2), capture.calls);
}

test "keyring config follows package configuration while user keyrings stay independent" {
    const t = std.testing;
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(t.io, .{ .sub_path = "custom.conf", .data = "[options]\nGPGDir = /custom/signing-keys\n" });
    const path = try temporary.dir.realPathFileAlloc(t.io, "custom.conf", t.allocator);
    defer t.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    const context: RuntimeContext = .{
        .allocator = t.allocator,
        .io = t.io,
        .stdout = &output.writer,
        .stderr = &output.writer,
        .config_path = path,
    };
    const args = try context.keyArguments(arena.allocator(), &.{ "shelly-key", "--init" });
    try t.expectEqualStrings("--gpgdir", args[2]);
    try t.expectEqualStrings("/custom/signing-keys", args[3]);
    const user_args = try context.keyArguments(arena.allocator(), &.{ "shelly-key", "--user", "--recv-keys", "KEY" });
    try t.expectEqual(@as(usize, 4), user_args.len);
}
