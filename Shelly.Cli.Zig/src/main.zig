const std = @import("std");
const Io = std.Io;

const Shelly_Cli_Zig = @import("Shelly_Cli_Zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const process_arguments = try init.minimal.args.toSlice(arena);
    const arguments = if (process_arguments.len > 0) process_arguments[1..] else process_arguments;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    // The Landlock sandbox wrapper re-executes the current executable with a
    // reserved first argument. Serve it before any CLI setup so the wrapped
    // step command never touches the dispatcher, session log, or signals.
    if (arguments.len > 0 and std.mem.eql(u8, arguments[0], Shelly_Cli_Zig.app.sandbox_wrapper_argument)) {
        const exit_code = Shelly_Cli_Zig.app.runSandboxExec(
            arena,
            init.minimal.environ,
            stderr_writer,
            arguments[1..],
        );
        stderr_writer.flush() catch {};
        std.process.exit(exit_code);
    }

    Shelly_Cli_Zig.signals.installInterruptHandler();
    var session_log = Shelly_Cli_Zig.log.SessionLog.tryOpen(io);
    defer if (session_log) |*log| log.close();
    if (session_log) |*log| log.writeSessionHeader(arena, arguments);
    var transaction_log: ?Shelly_Cli_Zig.log.TransactionLog = if (session_log) |*log|
        .init(log, arena)
    else
        null;

    var context: Shelly_Cli_Zig.runtime.RuntimeContext = .{
        .allocator = arena,
        .io = io,
        .stdin = &stdin_file_reader.interface,
        .stdout = stdout_writer,
        .stderr = stderr_writer,
        .environment = init.environ_map,
        .environ = init.minimal.environ,
        .stdin_is_tty = Io.File.stdin().isTty(io) catch false,
        .stdout_is_tty = Io.File.stdout().isTty(io) catch false,
        .dispatcher = .{ .call = Shelly_Cli_Zig.commands.dispatch },
        .transaction_log = if (transaction_log) |*log| log else null,
    };
    Shelly_Cli_Zig.download_policy.applyProcessDefault(&context);
    const exit_code = Shelly_Cli_Zig.app.run(&context, arguments) catch |err| code: {
        stderr_writer.print("shelly: {t}\n", .{err}) catch {};
        break :code 1;
    };
    if (session_log) |*log| log.writeSessionFooter(arena, exit_code);

    try stdout_writer.flush();
    try stderr_writer.flush();
    std.process.exit(exit_code);
}
