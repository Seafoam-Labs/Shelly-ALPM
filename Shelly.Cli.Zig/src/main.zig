const std = @import("std");
const Io = std.Io;

const Shelly_Cli_Zig = @import("Shelly_Cli_Zig");
const Zigalpm = @import("Zigalpm");

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

    // Isolated-root provisioning is also served before normal CLI setup. The
    // coordinator launches this reserved mode inside a private mount/PID
    // namespace; it performs one target-root libalpm transaction and emits no
    // normal command output.
    if (arguments.len > 0 and std.mem.eql(u8, arguments[0], Zigalpm.alpm.bootstrap.wrapper_argument)) {
        Zigalpm.HttpClient.setDefaultProxyEnvironment(init.environ_map);
        const exit_code = Zigalpm.alpm.bootstrap.runInternal(
            arena,
            io,
            init.minimal.environ,
            stderr_writer,
            arguments[1..],
        );
        stderr_writer.flush() catch {};
        std.process.exit(exit_code);
    }

    const proxy_environment = try Shelly_Cli_Zig.proxy_environment.prepare(
        arena,
        &stdin_file_reader.interface,
        init.minimal.environ,
        arguments,
    );
    const effective_arguments = proxy_environment.arguments;
    const effective_environment_map = proxy_environment.map(init.environ_map);
    Zigalpm.HttpClient.setDefaultProxyEnvironment(effective_environment_map);

    const graceful_cancellation = Shelly_Cli_Zig.signals.argumentsRequestGracefulCancellation(
        effective_arguments,
    );
    Shelly_Cli_Zig.signals.installInterruptHandler(graceful_cancellation);
    var session_log = Shelly_Cli_Zig.log.SessionLog.tryOpen(io);
    defer if (session_log) |*log| log.close();
    if (session_log) |*log| log.writeSessionHeader(arena, effective_arguments);
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
        .environment = effective_environment_map,
        .environ = proxy_environment.environ,
        .stdin_is_tty = Io.File.stdin().isTty(io) catch false,
        .stdout_is_tty = Io.File.stdout().isTty(io) catch false,
        .dispatcher = .{ .call = Shelly_Cli_Zig.commands.dispatch },
        .transaction_log = if (transaction_log) |*log| log else null,
    };
    Shelly_Cli_Zig.download_policy.applyProcessDefault(&context);
    const command_exit_code = Shelly_Cli_Zig.app.run(&context, effective_arguments) catch |err| code: {
        const message = Zigalpm.user_errors.format(arena, err, .{}) catch "Could not complete the package operation. Shelly could not allocate memory to explain the error.";
        var ui_mode = false;
        for (effective_arguments) |argument| {
            if (std.mem.eql(u8, argument, "--ui-mode")) ui_mode = true;
        }
        if (ui_mode) {
            Shelly_Cli_Zig.config_output.writeErrorFrame(&context, message) catch {};
        } else {
            stderr_writer.print("shelly: {s}\n", .{message}) catch {};
        }
        break :code 1;
    };
    const exit_code: u8 = if (Shelly_Cli_Zig.signals.wasInterrupted()) code: {
        stderr_writer.writeAll("Operation cancelled.\n") catch {};
        break :code 130;
    } else command_exit_code;
    if (session_log) |*log| log.writeSessionFooter(arena, exit_code);

    try stdout_writer.flush();
    try stderr_writer.flush();
    std.process.exit(exit_code);
}
