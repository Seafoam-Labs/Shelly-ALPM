//! Journaled data/signature publication. RLPM readers hold a shared directory
//! lock; publication/recovery hold the exclusive lock. A durable journal means
//! roll back; removing it is the commit point. Native clients still honor db.lck.
const std = @import("std");

extern "c" fn rlpm_directory_lock([*:0]const u8, c_int, c_int) c_int;
extern "c" fn rlpm_private_directory([*:0]const u8) c_int;

pub const DirectoryLock = struct {
    fd: c_int,

    pub fn acquire(path: []const u8, exclusive: bool, nonblock: bool) !DirectoryLock {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const terminated = try std.fmt.bufPrintZ(&buffer, "{s}", .{path});
        const fd = rlpm_directory_lock(terminated, @intFromBool(exclusive), @intFromBool(nonblock));
        if (fd < 0) return error.CacheBusy;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *DirectoryLock) void {
        _ = std.c.close(self.fd);
    }

    pub fn sync(self: DirectoryLock) !void {
        if (std.c.fsync(self.fd) != 0) return error.SyncFailed;
    }
};

pub fn privateDirectory(path: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (rlpm_private_directory(try std.fmt.bufPrintZ(&buffer, "{s}", .{path})) != 0)
        return error.UnsafeStagingDirectory;
}

fn exists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| return if (err == error.FileNotFound) false else err;
    return true;
}

fn remove(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| if (err != error.FileNotFound) return err;
}

/// Copy into caller-controlled staging, retaining the source modification time.
/// The caller must own the staging directory or hold its publication lock.
pub fn copy(io: std.Io, source: []const u8, target: []const u8) !void {
    // Unlink the replaceable name first; exclusive creation never follows an
    // existing symlink or truncates a file through an attacker-provided name.
    try remove(io, target);
    const input = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer input.close(io);
    const output = try std.Io.Dir.cwd().createFile(io, target, .{ .exclusive = true });
    defer output.close(io);
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try input.readPositional(io, &.{&buffer}, offset);
        if (n == 0) break;
        try output.writeStreamingAll(io, buffer[0..n]);
        offset += n;
    }
    try output.setTimestamps(io, .{ .modify_timestamp = .{ .new = (try input.stat(io)).mtime } });
    try output.setPermissions(io, .fromMode(0o644));
    try output.sync(io);
}

const Paths = struct {
    target: []const u8,
    signature: []const u8,
    journal: []const u8,
    old: []const u8,
    old_signature: []const u8,
    new: []const u8,
    new_signature: []const u8,

    fn init(a: std.mem.Allocator, path: []const u8) !Paths {
        return .{
            .target = path,
            .signature = try std.fmt.allocPrint(a, "{s}.sig", .{path}),
            .journal = try std.fmt.allocPrint(
                a,
                "{s}.rlpm-journal",
                .{path},
            ),
            .old = try std.fmt.allocPrint(
                a,
                "{s}.rlpm-old",
                .{path},
            ),
            .old_signature = try std.fmt.allocPrint(
                a,
                "{s}.sig.rlpm-old",
                .{path},
            ),
            .new = try std.fmt.allocPrint(
                a,
                "{s}.rlpm-new",
                .{path},
            ),
            .new_signature = try std.fmt.allocPrint(
                a,
                "{s}.sig.rlpm-new",
                .{path},
            ),
        };
    }
};

pub fn ensureReadable(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    const journal = try std.fmt.allocPrint(a, "{s}.rlpm-journal", .{path});
    defer a.free(journal);
    if (try exists(io, journal)) return error.DatabaseRecoveryRequired;
}

fn recoverLocked(io: std.Io, a: std.mem.Allocator, p: Paths, lock: DirectoryLock) !void {
    if (!try exists(io, p.journal)) return;
    const state = try std.Io.Dir.cwd().readFileAlloc(io, p.journal, a, .limited(3));
    if (state.len != 2 or state[0] > 1 or state[1] > 1) return error.InvalidPublicationJournal;
    // Keep backups intact until journal removal, making recovery idempotent.
    if (state[0] == 1) try copy(io, p.old, p.target) else try remove(io, p.target);
    if (state[1] == 1) try copy(io, p.old_signature, p.signature) else try remove(io, p.signature);
    try lock.sync();
    try remove(io, p.journal);
    try lock.sync();
}

pub fn recover(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lock = try DirectoryLock.acquire(std.fs.path.dirname(path).?, true, false);
    defer lock.deinit();
    try recoverLocked(io, arena.allocator(), try Paths.init(arena.allocator(), path), lock);
}

pub fn publish(
    io: std.Io,
    allocator: std.mem.Allocator,
    sealed: []const u8,
    signature: ?[]const u8,
    destination: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lock = try DirectoryLock.acquire(std.fs.path.dirname(destination).?, true, false);
    defer lock.deinit();
    const p = try Paths.init(a, destination);
    try recoverLocked(io, a, p, lock);
    const journal_new = try std.fmt.allocPrint(a, "{s}-new", .{p.journal});
    errdefer {
        // Keep recovery inputs only while a durable journal needs them.
        if (!(exists(io, p.journal) catch true)) {
            for ([_][]const u8{ p.old, p.old_signature, p.new, p.new_signature, journal_new }) |path|
                remove(io, path) catch {};
        }
    }
    try copy(io, sealed, p.new);
    const has_sig = signature != null;
    if (signature) |sig| try copy(io, sig, p.new_signature);
    const state = [2]u8{
        @intFromBool(try exists(io, destination)),
        @intFromBool(try exists(io, p.signature)),
    };
    if (state[0] == 1) try copy(io, destination, p.old);
    if (state[1] == 1) try copy(io, p.signature, p.old_signature);
    // Backups and their directory entries must survive before journal creation.
    try lock.sync();
    try remove(io, journal_new);
    const journal = try std.Io.Dir.cwd().createFile(io, journal_new, .{ .exclusive = true });
    defer journal.close(io);
    try journal.writeStreamingAll(io, &state);
    try journal.sync(io);
    try std.Io.Dir.cwd().rename(journal_new, .cwd(), p.journal, io);
    try lock.sync();
    errdefer recoverLocked(io, a, p, lock) catch {};
    try std.Io.Dir.cwd().rename(p.new, .cwd(), p.target, io);
    if (has_sig)
        try std.Io.Dir.cwd().rename(p.new_signature, .cwd(), p.signature, io)
    else
        try remove(io, p.signature);
    try lock.sync();
    try remove(io, p.journal);
    try lock.sync();
    // After the durable commit point, cleanup failure cannot undo publication.
    for ([_][]const u8{ p.old, p.old_signature, p.new, p.new_signature }) |path|
        remove(io, path) catch {};
}

test "publication recovery restores both old files before allowing readers" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const destination = try std.fmt.allocPrint(a, "{s}/repo.db", .{dir});
    defer a.free(destination);
    try temporary.dir.writeFile(io, .{ .sub_path = "repo.db.rlpm-old", .data = "old database" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo.db.sig.rlpm-old", .data = "old signature" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo.db", .data = "new database" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo.db.sig", .data = "old signature" });
    try temporary.dir.writeFile(io, .{ .sub_path = "repo.db.rlpm-journal", .data = &.{ 1, 1 } });
    try std.testing.expectError(error.DatabaseRecoveryRequired, ensureReadable(io, a, destination));
    try recover(io, a, destination);
    try recover(io, a, destination);
    try ensureReadable(io, a, destination);
    const bytes = try temporary.dir.readFileAlloc(io, "repo.db", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("old database", bytes);
    const sig = try temporary.dir.readFileAlloc(io, "repo.db.sig", a, .limited(100));
    defer a.free(sig);
    try std.testing.expectEqualStrings("old signature", sig);
}
