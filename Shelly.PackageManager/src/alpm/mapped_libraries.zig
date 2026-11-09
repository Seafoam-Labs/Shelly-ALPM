//! Reads mapped shared objects from procfs and tracks which of them were
//! replaced while a package transaction was running.
//!
//! Post-upgrade restarts must only consider libraries touched by the current
//! transaction. A process which has carried a deleted library since an older
//! upgrade is already stale, but restarting its service again after every
//! unrelated transaction is both surprising and disruptive. `LibrarySnapshot`
//! records the on-disk inode of every shared object mapped by a live process
//! before the transaction; after the transaction, only paths whose on-disk
//! inode changed are considered.

const std = @import("std");
const builtin = @import("builtin");
const pseudo_file = @import("../shared/pseudo_file.zig");

const deleted_suffix = " (deleted)";
const max_maps_size = 16 * 1024 * 1024;

/// A shared-object mapping parsed from `/proc/<pid>/maps`.
pub const MapEntry = struct {
    inode: u64,
    path: []const u8,
    deleted: bool,
};

/// The identity of a path on disk at one point in time. `present` is false
/// when the path could not be inspected, so a later successful stat counts as
/// a change.
pub const LibraryState = struct {
    present: bool,
    inode: u64,

    pub fn eql(lhs: LibraryState, rhs: LibraryState) bool {
        return lhs.present == rhs.present and (!lhs.present or lhs.inode == rhs.inode);
    }
};

/// On-disk identity of every shared object mapped by a process.
pub const LibrarySnapshot = struct {
    allocator: std.mem.Allocator,
    states: std.StringHashMapUnmanaged(LibraryState) = .empty,

    pub fn capture(
        io: std.Io,
        allocator: std.mem.Allocator,
        proc_root: []const u8,
    ) error{ OutOfMemory, ProcUnavailable }!LibrarySnapshot {
        var self = LibrarySnapshot{ .allocator = allocator };
        errdefer self.deinit();

        var proc_dir = std.Io.Dir.cwd().openDir(io, proc_root, .{ .iterate = true }) catch
            return error.ProcUnavailable;
        defer proc_dir.close(io);

        var iterator = proc_dir.iterateAssumeFirstIteration();
        while (true) {
            const next_entry = iterator.next(io) catch break;
            const entry = next_entry orelse break;
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;

            const maps_path = std.fs.path.join(allocator, &.{ proc_root, entry.name, "maps" }) catch
                return error.OutOfMemory;
            defer allocator.free(maps_path);
            const maps = pseudo_file.readAlloc(io, allocator, maps_path, .limited(max_maps_size)) catch continue;
            defer allocator.free(maps);

            var lines = std.mem.splitScalar(u8, maps, '\n');
            while (lines.next()) |line| {
                const parsed = parseMapEntry(line) orelse continue;
                if (!isSharedObjectPath(parsed.path)) continue;
                if (self.states.contains(parsed.path)) continue;

                const owned = allocator.dupe(u8, parsed.path) catch return error.OutOfMemory;
                errdefer allocator.free(owned);
                self.states.put(allocator, owned, statLibrary(io, parsed.path)) catch
                    return error.OutOfMemory;
            }
        }
        return self;
    }

    pub fn deinit(self: *LibrarySnapshot) void {
        deinitStates(&self.states, self.allocator);
        self.* = undefined;
    }

    /// Inserts each library whose current on-disk inode differs from the
    /// captured one. The output owns its keys and states.
    pub fn collectChanges(
        self: *const LibrarySnapshot,
        io: std.Io,
        allocator: std.mem.Allocator,
        out: *std.StringHashMapUnmanaged(LibraryState),
    ) error{OutOfMemory}!void {
        var iterator = self.states.iterator();
        while (iterator.next()) |entry| {
            const current = statLibrary(io, entry.key_ptr.*);
            if (LibraryState.eql(entry.value_ptr.*, current)) continue;
            const owned = allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
            errdefer allocator.free(owned);
            out.put(allocator, owned, current) catch return error.OutOfMemory;
        }
    }
};

pub fn deinitStates(states: *std.StringHashMapUnmanaged(LibraryState), allocator: std.mem.Allocator) void {
    var keys = states.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    states.deinit(allocator);
    states.* = .empty;
}

fn statLibrary(io: std.Io, path: []const u8) LibraryState {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch
        return .{ .present = false, .inode = 0 };
    return .{ .present = true, .inode = stat.inode };
}

/// Parses `address perms offset dev inode pathname` while preserving spaces in
/// the pathname. Anonymous and otherwise pathless mappings return null.
pub fn parseMapEntry(line: []const u8) ?MapEntry {
    var rest = std.mem.trimEnd(u8, line, " \t\r");
    if (rest.len == 0) return null;

    var inode: u64 = 0;
    var field: usize = 0;
    while (field < 5) : (field += 1) {
        const start = std.mem.indexOfNone(u8, rest, " \t") orelse return null;
        rest = rest[start..];
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
        if (field == 4) inode = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
        rest = rest[end..];
    }

    const path_start = std.mem.indexOfNone(u8, rest, " \t") orelse return null;
    var path = rest[path_start..];
    const deleted = std.mem.endsWith(u8, path, deleted_suffix);
    if (deleted) path = path[0 .. path.len - deleted_suffix.len];
    if (path.len == 0) return null;
    return .{ .inode = inode, .path = path, .deleted = deleted };
}

/// A process is stale when it maps a shared object whose file was replaced.
/// Only the mapped path's basename counts, and it must be `*.so` or
/// `*.so.<version>`: `/etc/ld.so.cache (deleted)`, which ldconfig leaves in
/// nearly every process (PID 1 included) after each transaction, and
/// `/memfd:... (deleted)` are not shared libraries. Exotic suffixes such as
/// `libfoo.so.1-1` are missed, which the next transaction's scan tolerates.
pub fn hasDeletedSharedLibrary(maps: []const u8) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const entry = parseMapEntry(line) orelse continue;
        if (entry.deleted and isSharedObjectPath(entry.path)) return true;
    }
    return false;
}

pub fn isSharedObjectPath(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    const index = std.mem.lastIndexOf(u8, name, ".so") orelse return false;
    const rest = name[index + ".so".len ..];
    if (rest.len == 0) return true;
    if (rest.len == 1 or rest[0] != '.') return false;
    for (rest[1..]) |ch| {
        if (!std.ascii.isDigit(ch) and ch != '.') return false;
    }
    return true;
}

test "map entries preserve path names and expose deleted state" {
    const testing = std.testing;
    const with_spaces = parseMapEntry("7f00-7f01 r-xp 00000000 00:1f 42 /home/user/my libs/libfoo.so.1 (deleted)") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 42), with_spaces.inode);
    try testing.expectEqualStrings("/home/user/my libs/libfoo.so.1", with_spaces.path);
    try testing.expect(with_spaces.deleted);

    const active = parseMapEntry("7f00-7f01 r-xp 00000000 00:1f 7 /usr/lib/libdemo.so.1") orelse return error.TestUnexpectedResult;
    try testing.expect(!active.deleted);
    try testing.expectEqual(@as(u64, 7), active.inode);

    try testing.expect(parseMapEntry("7f00-7f01 rw-p 00000000 00:00 0") == null);
    try testing.expect(parseMapEntry("") == null);
}

test "only deleted shared objects make a process stale" {
    const testing = std.testing;
    try testing.expect(hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/libXdmcp.so.6.0.0 (deleted)\n"));
    try testing.expect(hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/ld-linux-x86-64.so.2 (deleted)\n"));
    try testing.expect(hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/python3.14/lib-dynload/_ssl.cpython-314-x86_64-linux-gnu.so (deleted)\n"));
    try testing.expect(hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /home/user/my libs/libfoo.so.1 (deleted)\n"));
    try testing.expect(!hasDeletedSharedLibrary("7f00-7f01 r--p 00000000 00:1f 42 /etc/ld.so.cache (deleted)\n"));
    try testing.expect(!hasDeletedSharedLibrary("7f00-7f01 rw-s 00000000 00:01 42 /memfd:doublemapper (deleted)\n"));
    try testing.expect(!hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /var/log/journal/system.journal (deleted)\n"));
    try testing.expect(!hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /usr/bin/demo (deleted)\n"));
    try testing.expect(!hasDeletedSharedLibrary("7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/libdemo.so.1\n"));
}

test "snapshot of the real procfs is stable without a transaction" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var snapshot = try LibrarySnapshot.capture(testing.io, testing.allocator, "/proc");
    defer snapshot.deinit();
    try testing.expect(snapshot.states.count() > 0);

    var changed: std.StringHashMapUnmanaged(LibraryState) = .empty;
    defer deinitStates(&changed, testing.allocator);
    try snapshot.collectChanges(testing.io, testing.allocator, &changed);
    try testing.expectEqual(@as(usize, 0), changed.count());
}

test "snapshot reports only libraries replaced after capture" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "libdemo.so.1", .data = "first" });
    const library = try tmp.dir.realPathFileAlloc(io, "libdemo.so.1", testing.allocator);
    defer testing.allocator.free(library);

    try tmp.dir.createDirPath(io, "proc/123");
    const proc_root = try tmp.dir.realPathFileAlloc(io, "proc", testing.allocator);
    defer testing.allocator.free(proc_root);

    const maps_path = try std.fs.path.join(testing.allocator, &.{ proc_root, "123", "maps" });
    defer testing.allocator.free(maps_path);
    const maps = try std.fmt.allocPrint(testing.allocator, "7f00-7f01 r-xp 00000000 00:1f 42 {s}\n", .{library});
    defer testing.allocator.free(maps);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = maps_path, .data = maps });

    var snapshot = try LibrarySnapshot.capture(io, testing.allocator, proc_root);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 1), snapshot.states.count());

    var unchanged: std.StringHashMapUnmanaged(LibraryState) = .empty;
    defer deinitStates(&unchanged, testing.allocator);
    try snapshot.collectChanges(io, testing.allocator, &unchanged);
    try testing.expectEqual(@as(usize, 0), unchanged.count());

    try tmp.dir.writeFile(io, .{ .sub_path = "replacement", .data = "second" });
    try tmp.dir.rename("replacement", tmp.dir, "libdemo.so.1", io);

    var changed: std.StringHashMapUnmanaged(LibraryState) = .empty;
    defer deinitStates(&changed, testing.allocator);
    try snapshot.collectChanges(io, testing.allocator, &changed);
    try testing.expectEqual(@as(usize, 1), changed.count());
    try testing.expect(changed.get(library) != null);
}
