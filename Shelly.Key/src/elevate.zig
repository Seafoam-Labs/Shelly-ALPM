const std = @import("std");

pub const ElevateError = error{
    NoElevator,
    ExecFailed,
};

const Elevator = enum {
    sudo,
    doas,
    pkexec,
};

fn findElevator(io: std.Io, gpa: std.mem.Allocator, path_env: []const u8) ?Elevator {
    const binaries = std.meta.fieldNames(Elevator);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        for (binaries, 0..) |bin, i| {
            const full_path = std.fs.path.join(gpa, &.{ path, bin }) catch continue;
            defer gpa.free(full_path);
            std.Io.Dir.accessAbsolute(io, full_path, .{}) catch continue;
            return @enumFromInt(i);
        }
    }
    return null;
}

pub fn ensureRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
) !void {
    const uid = std.os.linux.getuid();
    if (uid == 0) return;

    const elevator = findElevator(io, allocator, path_env) orelse return error.NoElevator;

    const exe = std.process.executablePathAlloc(io, allocator) catch return error.ExecFailed;
    defer allocator.free(exe);

    var new_args: std.ArrayList([]const u8) = .empty;
    defer new_args.deinit(allocator);

    const bin_name = @tagName(elevator);
    try new_args.append(allocator, bin_name);
    try new_args.append(allocator, exe);
    for (args[1..]) |arg| try new_args.append(allocator, arg);

    var child = std.process.spawn(io, .{
        .argv = new_args.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.ExecFailed;

    const term = child.wait(io) catch return error.ExecFailed;

    switch (term) {
        .exited => |code| std.process.exit(code),
        // Mirror the shell convention of 128 + signum for signal termination.
        .signal => |sig| std.process.exit(@truncate(128 + @intFromEnum(sig))),
        else => return error.ExecFailed,
    }
}
