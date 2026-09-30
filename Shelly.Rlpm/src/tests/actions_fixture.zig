const std = @import("std");
const rlpm = @import("Shelly_Rlpm");
const worker_fixture = @import("worker_fixture");

const a = std.testing.allocator;
const io = std.testing.io;
const Fixture = @This();
tmp: std.testing.TmpDir,
root: [:0]u8,
db: [:0]u8,

pub fn init() !Fixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "db/local");
    try tmp.dir.writeFile(io, .{ .sub_path = "db/local/ALPM_DB_VERSION", .data = "9\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "root", a);
    errdefer a.free(root);
    return .{
        .tmp = tmp,
        .root = root,
        .db = try tmp.dir.realPathFileAlloc(io, "db", a),
    };
}

pub fn deinit(self: *Fixture) void {
    a.free(self.root);
    a.free(self.db);
    self.tmp.cleanup();
}

pub fn owner(self: *Fixture) !rlpm.Owner {
    const worker_path = try std.Io.Dir.cwd().realPathFileAlloc(io, worker_fixture.path, a);
    defer a.free(worker_path);
    return rlpm.Owner.init(io, a, .{ .root = self.root, .database_path = self.db, .worker_executable = worker_path }, &.{});
}

pub fn write(self: *Fixture, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(io, parent);
    try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = contents });
}

pub fn read(self: *Fixture, path: []const u8) ![]u8 {
    return self.tmp.dir.readFileAlloc(io, path, a, .limited(1024 * 1024));
}

pub fn expect(self: *Fixture, path: []const u8, expected: []const u8) !void {
    const contents = try self.read(path);
    defer a.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
}

pub fn installed(
    self: *Fixture,
    name: []const u8,
    version: []const u8,
    files: []const u8,
    install: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const directory = try std.fmt.allocPrint(alloc, "db/local/{s}-{s}", .{ name, version });
    try self.write(
        try std.fmt.allocPrint(alloc, "{s}/desc", .{directory}),
        try std.fmt.allocPrint(
            alloc,
            "%NAME%\n{s}\n\n%VERSION%\n{s}\n\n%REASON%\n0\n\n",
            .{ name, version },
        ),
    );
    try self.write(
        try std.fmt.allocPrint(alloc, "{s}/files", .{directory}),
        try std.fmt.allocPrint(
            alloc,
            "%FILES%\n{s}\n\n",
            .{files},
        ),
    );
    if (install) |script|
        try self.write(try std.fmt.allocPrint(alloc, "{s}/install", .{directory}), script);
}

/// Only trusted host bash and its loader/libraries are copied. No host hooks,
/// shell startup files, service managers, or ldconfig are placed in this root.
pub fn shell(self: *Fixture) !void {
    try self.executable("/usr/bin/bash", "root/usr/bin/bash");
}

pub fn executable(self: *Fixture, source: []const u8, destination: []const u8) !void {
    try self.tmp.dir.createDirPath(io, std.fs.path.dirname(destination).?);
    try std.Io.Dir.cwd().copyFile(source, self.tmp.dir, destination, io, .{});
    const dependencies = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/ldd", source } });
    defer a.free(dependencies.stdout);
    defer a.free(dependencies.stderr);
    if (dependencies.term != .exited or dependencies.term.exited != 0)
        return error.FixtureShellUnavailable;
    var words = std.mem.tokenizeAny(u8, dependencies.stdout, " \t\r\n");
    while (words.next()) |word|
        if (std.mem.startsWith(u8, word, "/")) try self.copy(word);
}

pub fn copy(self: *Fixture, path: []const u8) !void {
    const destination = try std.fmt.allocPrint(a, "root{s}", .{path});
    defer a.free(destination);
    try self.tmp.dir.createDirPath(io, std.fs.path.dirname(destination).?);
    try std.Io.Dir.cwd().copyFile(path, self.tmp.dir, destination, io, .{});
}

pub fn hook(self: *Fixture, name: []const u8, body: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "root/usr/share/libalpm/hooks/{s}", .{name});
    defer a.free(path);
    try self.write(path, body);
}

pub fn add(tx: *rlpm.Transaction, path: []const u8) !void {
    var package: ?rlpm.Package = try tx.owner.loadPackage(io, path, .local_file, .{});
    defer if (package) |*value| value.deinit();
    try tx.takeArchive(&package);
}

/// Enter the committing state so fixtures can exercise action stages independently
/// of the production payload and local database executor.
pub fn enter(tx: *rlpm.Transaction) void {
    tx.owner.busy = true;
    tx.state = .committing;
}

pub fn leave(tx: *rlpm.Transaction) void {
    tx.owner.busy = false;
    tx.state = .prepared;
}
