//! Test-only embedding host: exercise the real parent transport after replacement.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (rlpm.Workers.dispatch(init, args[1..])) |status| std.process.exit(status);
    if (args.len == 1) {
        const directory = try rlpm.Downloads.uniquePath(a, io, "/tmp", "rlpm-self-execution");
        try std.Io.Dir.cwd().createDir(io, directory, .fromMode(0o700));
        defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
        const executable = try std.fs.path.join(a, &.{ directory, "host" });
        try std.Io.Dir.copyFile(.cwd(), rlpm.Workers.self_executable, .cwd(), executable, io, .{});
        try std.Io.Dir.cwd().setFilePermissions(io, executable, .fromMode(0o700), .{});
        var child = try std.process.spawn(io, .{ .argv = &.{ executable, directory } });
        defer child.kill(io);
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.SelfExecutionFailed;
        return;
    }
    if (args.len != 2) return error.InvalidArguments;
    // Remove the loaded inode's pathname and put an unrelated executable there.
    // Resolving selfExePath or searching siblings would now run the wrong file.
    try std.Io.Dir.cwd().deleteFile(io, args[0]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[0], .data = "#!/bin/sh\nexit 99\n" });
    try std.Io.Dir.cwd().setFilePermissions(io, args[0], .fromMode(0o700), .{});
    var owner = try rlpm.Owner.init(io, init.gpa, .{
        .root = "/",
        .database_path = args[1],
        .hook_directories = &.{},
    }, &.{});
    defer owner.deinit() catch unreachable;
    var manifest = try rlpm.ExecutionManifest.init(init.gpa, "/", args[1]);
    defer manifest.deinit();
    const result = try rlpm.ActionProcess.run(&owner, io, .{
        .root = &manifest.root,
        .argv = &.{ "/bin/sh", "-c", "exit 37" },
        .network = .allowed,
    });
    if (result.setup_failure != null or result.term != .exited or result.term.exited != 37)
        return error.WrongExecutable;
}
