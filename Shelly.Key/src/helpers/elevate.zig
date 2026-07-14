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
    arena: *std.heap.ArenaAllocator,
    args: []const []const u8,
    path_env: []const u8,
) !void {
    const uid = std.os.linux.getuid();
    if (uid == 0) return;

    const gpa = arena.allocator();
    const elevator = findElevator(io, gpa, path_env) orelse return error.NoElevator;

    const exe = try std.process.executablePathAlloc(io, gpa);

    var new_args: std.ArrayList([]const u8) = .empty;

    const bin_name = @tagName(elevator);
    try new_args.append(gpa, bin_name);
    try new_args.append(gpa, exe);
    for (args[1..]) |arg| try new_args.append(gpa, arg);

    var child = try std.process.spawn(io, .{
        .argv = new_args.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    const term = try child.wait(io);
    try handleTerm(term);
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
