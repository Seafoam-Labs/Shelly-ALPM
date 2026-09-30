const std = @import("std");
const Database = @import("Database.zig");

// Simulate only GPG's process and stdout operations, without accessing a keyring.
const SignatureTestIo = struct {
    output: []const u8 = "[GNUPG:] GOODSIG test-key Test Signer\n",
    term: std.process.Child.Term = .{ .exited = 0 },
    spawn_error: ?std.process.SpawnError = null,
    read_error: ?std.Io.Operation.FileReadStreaming.Error = null,
    spawned: bool = false,
    closed: bool = false,
    waited: bool = false,
    killed: bool = false,

    const vtable: std.Io.VTable = blk: {
        var result = std.Io.failing.vtable.*;
        result.processSpawn = spawn;
        result.operate = operate;
        result.fileClose = close;
        result.childWait = wait;
        result.childKill = kill;
        break :blk result;
    };

    fn io(self: *SignatureTestIo) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    fn fromContext(context: ?*anyopaque) *SignatureTestIo {
        return @ptrCast(@alignCast(context.?));
    }

    fn spawn(context: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
        const self = fromContext(context);
        self.spawned = true;
        std.debug.assert(std.mem.eql(u8, options.argv[0], "gpg"));
        std.debug.assert(options.stdout == .pipe);
        if (self.spawn_error) |err| return err;
        return .{
            .id = std.mem.zeroes(std.process.Child.Id),
            .thread_handle = undefined,
            .stdin = null,
            .stdout = .{ .handle = std.mem.zeroes(std.Io.File.Handle), .flags = .{ .nonblocking = false } },
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    }

    fn operate(context: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self = fromContext(context);
        const read = operation.file_read_streaming;
        if (self.read_error) |err| return .{ .file_read_streaming = err };
        if (self.output.len == 0) return .{ .file_read_streaming = error.EndOfStream };
        // Deliver small chunks to exercise capture across multiple reads.
        const count = @min(read.data[0].len, self.output.len, 7);
        @memcpy(read.data[0][0..count], self.output[0..count]);
        self.output = self.output[count..];
        return .{ .file_read_streaming = count };
    }

    fn close(context: ?*anyopaque, _: []const std.Io.File) void {
        fromContext(context).closed = true;
    }

    fn wait(context: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const self = fromContext(context);
        self.waited = true;
        child.id = null;
        return self.term;
    }

    fn kill(context: ?*anyopaque, child: *std.process.Child) void {
        const self = fromContext(context);
        self.killed = true;
        if (child.stdout != null) self.closed = true;
        child.stdout = null;
        child.id = null;
    }
};

test "validateSignature accepts a successful GPG exit" {
    var database = try Database.init(std.testing.allocator, "extra", "/test/sync", .{});
    defer database.deinit();

    var fake: SignatureTestIo = .{};
    try std.testing.expect(try database.validateSignature(fake.io(), null));
    try std.testing.expect(fake.spawned and fake.closed and fake.waited);
    try std.testing.expect(!fake.killed);
}

test "validateSignature rejects unsuccessful GPG termination" {
    var database = try Database.init(std.testing.allocator, "extra", "/test/sync", .{});
    defer database.deinit();

    const terms: []const std.process.Child.Term = &.{
        .{ .exited = 1 },
        .{ .exited = 2 },
        .{ .signal = .TERM },
        .{ .stopped = .TERM },
        .{ .unknown = 0x7f },
    };
    for (terms) |term| {
        // Even apparently successful status text must not override failure.
        var fake: SignatureTestIo = .{ .term = term };
        try std.testing.expect(!try database.validateSignature(fake.io(), null));
        try std.testing.expect(fake.closed and fake.waited);
    }
}

test "validateSignature propagates process and read errors" {
    var database = try Database.init(std.testing.allocator, "extra", "/test/sync", .{});
    defer database.deinit();

    var missing_gpg: SignatureTestIo = .{ .spawn_error = error.FileNotFound };
    try std.testing.expectError(error.FileNotFound, database.validateSignature(missing_gpg.io(), null));
    try std.testing.expect(missing_gpg.spawned and !missing_gpg.waited);

    var failed_read: SignatureTestIo = .{ .read_error = error.InputOutput };
    try std.testing.expectError(error.InputOutput, database.validateSignature(failed_read.io(), null));
    try std.testing.expect(failed_read.closed and failed_read.killed);
    try std.testing.expect(!failed_read.waited);
}

test "validateSignature cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            var database = try Database.init(allocator, "extra", "/test/sync", .{});
            defer database.deinit();
            var fake: SignatureTestIo = .{};
            try std.testing.expect(try database.validateSignature(fake.io(), null));
        }
    }.check, .{});
}
