const std = @import("std");
test "native sandbox confines only fresh children across filesystem and syscall switches" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const parent_uid = std.c.getuid();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    for (0..4) |bits| {
        const name = try std.fmt.allocPrint(a, "case-{d}", .{bits});
        defer a.free(name);
        try temporary.dir.createDir(io, name, .fromMode(0o700));
        const stage = try std.fs.path.join(a, &.{ root, name });
        defer a.free(stage);
        const outside = try std.fmt.allocPrint(a, "{s}/outside-{d}", .{ root, bits });
        defer a.free(outside);
        const flags = try std.fmt.allocPrint(a, "{d}", .{bits});
        defer a.free(flags);
        const result = try std.process.run(a, io, .{ .argv = &.{ @import("sandbox_fixture").path, stage, outside, flags }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("sandbox switches {d}: {s}\n", .{ bits, result.stderr });
            return error.SandboxFixtureFailed;
        }
        try std.testing.expectEqual(parent_uid, std.c.getuid());
    }
    // Child restrictions must not change the parent's filesystem access.
    try temporary.dir.writeFile(io, .{ .sub_path = "parent-write", .data = "allowed" });
}
