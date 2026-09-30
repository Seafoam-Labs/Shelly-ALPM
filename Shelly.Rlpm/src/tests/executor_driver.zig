//! Test-only interoperability driver. Requires a Python-created private fixture
//! marker; never supplies host defaults or joins the installed CLI.
const std = @import("std");
const rlpm = @import("Shelly_Rlpm");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.InvalidArguments;
    const base = args[1];
    if (!std.mem.startsWith(u8, base, "/tmp/rlpm-executor-interop-")) return error.NotFixture;
    const root = try std.fs.path.join(a, &.{ base, "root" });
    const db = try std.fs.path.join(a, &.{ base, "db" });
    const marker = try std.fs.path.join(a, &.{ base, ".fixture" });
    const guard = try std.Io.Dir.cwd().readFileAlloc(init.io, marker, a, .limited(100));
    if (!std.mem.eql(u8, guard, "disposable RLPM executor interoperability\n")) return error.NotFixture;
    var owner = try rlpm.Owner.init(
        init.io,
        init.gpa,
        .{
            .root = root,
            .database_path = db,
            .hook_directories = &.{},
        },
        &.{},
    );
    defer owner.deinit() catch unreachable;
    if (std.mem.eql(u8, args[2], "install")) {
        const tx = try owner.initializeTransaction(
            init.io,
            .{
                .no_hooks = true,
                .no_scriptlets = true,
                .no_dependencies = true,
            },
        );
        defer owner.releaseTransaction() catch unreachable;
        var package: ?rlpm.Package = try owner.loadPackage(init.io, args[3], .local_file, .{});
        defer if (package) |*value| value.deinit();
        try tx.takeArchive(&package);
        try tx.prepare();
        try tx.commit();
    } else if (!std.mem.eql(u8, args[2], "query")) return error.InvalidArguments;
    const reference = (try owner.findPackage(owner.localDatabase().?, "demo")) orelse
        return error.PackageMissing;
    const package = try owner.packageMetadata(init.io, reference, .{ .files = true, .members = true });
    if (!std.mem.eql(u8, package.version.raw, args[4])) return error.WrongVersion;
    if (package.install_date == null or package.files.len == 0 or package.backups.len == 0 or
        !package.validation.none)
        return error.MissingMetadata;
    if (package.members.changelog != .present or package.members.install != .present or
        package.members.mtree != .present)
        return error.MissingMembers;
}
