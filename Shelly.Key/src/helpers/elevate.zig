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

pub fn ensureRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    path_env: []const u8,
) !void {
    const uid = std.os.linux.getuid();
    if (uid == 0) return;

    const elevator = findElevator(io, allocator, path_env) orelse return error.NoElevator;

    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);

    const new_args = try buildElevatedCmd(allocator, elevator, exe, args);
    defer allocator.free(new_args);

    var child = try std.process.spawn(io, .{
        .argv = new_args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const term = try child.wait(io);
    try handleTerm(term);
}

fn findElevator(io: std.Io, allocator: std.mem.Allocator, path_env: []const u8) ?Elevator {
    const binaries = std.meta.fieldNames(Elevator);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        for (binaries, 0..) |bin, i| {
            const full_path = std.fs.path.join(allocator, &.{ path, bin }) catch continue;
            defer allocator.free(full_path);
            std.Io.Dir.accessAbsolute(io, full_path, .{}) catch continue;
            return @enumFromInt(i);
        }
    }
    return null;
}

fn buildElevatedCmd(
    allocator: std.mem.Allocator,
    elevator: Elevator,
    exe_path: []const u8,
    args: []const []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, @tagName(elevator));
    try list.append(allocator, exe_path);
    for (args[1..]) |arg| try list.append(allocator, arg);
    return list.toOwnedSlice(allocator);
}

fn handleTerm(term: std.process.Child.Term) ElevateError!noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        // Mirror the shell convention of 128 + signum for signal termination.
        .signal => |sig| std.process.exit(@truncate(128 + @intFromEnum(sig))),
        .stopped => |sig| {
            std.log.err("elevator stopped by signal {s}", .{@tagName(sig)});
            return error.ExecFailed;
        },
        .unknown => |status| {
            std.log.err("elevator unknown status 0x{x}", .{status});
            return error.ExecFailed;
        },
    }
}

const testing = std.testing;

fn createFakeBinary(dir: std.Io.Dir, io: std.Io, name: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    f.close(io);
}

test "findElevator returns null for an empty PATH" {
    try testing.expectEqual(
        @as(?Elevator, null),
        findElevator(testing.io, testing.allocator, ""),
    );
}

test "findElevator returns null when PATH has no elevator" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const path_env = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path_env);

    try testing.expectEqual(
        @as(?Elevator, null),
        findElevator(testing.io, testing.allocator, path_env),
    );
}

test "findElevator finds sudo" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFakeBinary(tmp.dir, testing.io, "sudo");

    const path_env = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path_env);

    try testing.expectEqual(
        @as(?Elevator, .sudo),
        findElevator(testing.io, testing.allocator, path_env),
    );
}

test "findElevator finds doas" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFakeBinary(tmp.dir, testing.io, "doas");

    const path_env = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path_env);

    try testing.expectEqual(
        @as(?Elevator, .doas),
        findElevator(testing.io, testing.allocator, path_env),
    );
}

test "findElevator picks the first matching directory in PATH" {
    var tmp_empty = testing.tmpDir(.{ .iterate = true });
    defer tmp_empty.cleanup();
    var tmp_doas = testing.tmpDir(.{ .iterate = true });
    defer tmp_doas.cleanup();
    try createFakeBinary(tmp_doas.dir, testing.io, "doas");

    const first = try tmp_empty.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(first);
    const second = try tmp_doas.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(second);

    const path_env = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ first, second });
    defer testing.allocator.free(path_env);

    try testing.expectEqual(
        @as(?Elevator, .doas),
        findElevator(testing.io, testing.allocator, path_env),
    );
}

test "findElevator skips empty PATH segments" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFakeBinary(tmp.dir, testing.io, "pkexec");

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    // Leading, middle, and trailing empty segments.
    const path_env = try std.fmt.allocPrint(testing.allocator, "::{s}::", .{dir_path});
    defer testing.allocator.free(path_env);

    try testing.expectEqual(
        @as(?Elevator, .pkexec),
        findElevator(testing.io, testing.allocator, path_env),
    );
}

test "buildElevatedCmd produces minimal command" {
    const cmd = try buildElevatedCmd(
        testing.allocator,
        .sudo,
        "/usr/bin/myapp",
        &.{"myapp"},
    );
    defer testing.allocator.free(cmd);

    try testing.expectEqualSlices(u8, cmd[0], "sudo");
    try testing.expectEqualSlices(u8, cmd[1], "/usr/bin/myapp");
    try testing.expectEqual(@as(usize, 2), cmd.len);
}

test "buildElevatedCmd forwards extra arguments" {
    const cmd = try buildElevatedCmd(
        testing.allocator,
        .doas,
        "/path/to/exe",
        &.{ "prog", "--verbose", "--target", "/foo" },
    );
    defer testing.allocator.free(cmd);

    try testing.expectEqual(@as(usize, 5), cmd.len);
    try testing.expectEqualSlices(u8, cmd[0], "doas");
    try testing.expectEqualSlices(u8, cmd[1], "/path/to/exe");
    try testing.expectEqualSlices(u8, cmd[2], "--verbose");
    try testing.expectEqualSlices(u8, cmd[3], "--target");
    try testing.expectEqualSlices(u8, cmd[4], "/foo");
}

test "buildElevatedCmd skips args[0]" {
    const cmd = try buildElevatedCmd(
        testing.allocator,
        .pkexec,
        "/exe",
        &.{ "myapp", "arg1" },
    );
    defer testing.allocator.free(cmd);

    try testing.expectEqual(@as(usize, 3), cmd.len);
    try testing.expectEqualSlices(u8, cmd[0], "pkexec");
    try testing.expectEqualSlices(u8, cmd[1], "/exe");
    try testing.expectEqualSlices(u8, cmd[2], "arg1");
}
