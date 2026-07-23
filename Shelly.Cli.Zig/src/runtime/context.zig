const std = @import("std");
const Zigalpm = @import("Zigalpm");
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
    stdin_is_tty: bool = false,
    stdout_is_tty: bool = false,
    dispatcher: Dispatcher = .{},
    transaction_log: ?*log.TransactionLog = null,

    pub fn dispatch(self: *RuntimeContext, invocation: *const parser.Invocation) !u8 {
        return self.dispatcher.call(self.dispatcher.user_data, self, invocation);
    }

    pub fn attachTransactionLog(
        self: *RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
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
        "Command '{s}' has not been ported to Zig yet.\n",
        .{invocation.command.path},
    );
    return 1;
}
