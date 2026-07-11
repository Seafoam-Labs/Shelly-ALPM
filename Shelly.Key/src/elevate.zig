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

fn findElevator(init: std.process.Init) ?Elevator {
    const path_env = init.environ_map.get("PATH") orelse return null;
    const allocator = init.gpa;

    const binaries = std.meta.fieldNames(Elevator);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        for (binaries, 0..) |bin, i| {
            const full_path = std.fs.path.join(allocator, &.{ path, bin }) catch continue;
            defer allocator.free(full_path);
            std.Io.Dir.accessAbsolute(init.io, full_path, .{}) catch continue;
            return @enumFromInt(i);
        }
    }
    return null;
}

pub fn ensureRoot(init: std.process.Init) !void {
    const uid = std.os.linux.getuid();
    if (uid == 0) return;

    const elevator = findElevator(init) orelse return error.NoElevator;

    const allocator = init.gpa;
    const exe = std.process.executablePathAlloc(init.io, allocator) catch return error.ExecFailed;
    defer allocator.free(exe);

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var new_args: std.ArrayList([]const u8) = .empty;
    defer new_args.deinit(allocator);

    const bin_name = @tagName(elevator);
    try new_args.append(allocator, bin_name);
    try new_args.append(allocator, exe);
    for (args[1..]) |arg| try new_args.append(allocator, arg);

    var child = std.process.spawn(init.io, .{
        .argv = new_args.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.ExecFailed;

    const term = child.wait(init.io) catch return error.ExecFailed;

    switch (term) {
        .exited => |code| std.process.exit(code),
        // Mirror the shell convention of 128 + signum for signal termination.
        .signal => |sig| std.process.exit(@truncate(128 + @intFromEnum(sig))),
        else => return error.ExecFailed,
    }
}
