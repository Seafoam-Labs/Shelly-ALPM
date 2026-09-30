//! Content fingerprint of local/sync state. db.lck is intentionally excluded.
//! Reading under the cooperative lock prevents legitimate writers racing us;
//! rechecking detects out-of-band edits before a reviewed plan can be applied.
const std = @import("std");
const Owner = @import("Owner.zig");

const Hash = std.crypto.hash.sha2.Sha256;

const Progress = struct {
    owner: *Owner,
    io: std.Io,
    reported: std.Io.Timestamp,
    files: u64 = 0,
    bytes: u64 = 0,

    fn report(self: *Progress, complete: bool) void {
        const callbacks = self.owner.configuration.callbacks;
        const log = callbacks.log orelse return;
        const now = std.Io.Clock.awake.now(self.io);
        if (!complete and self.reported.durationTo(now).toMilliseconds() < 250) return;
        self.reported = now;
        var buffer: [192]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{s}: {d} files checked, {d} bytes read", .{
            if (complete) "Package database checks complete" else "Checking package databases",
            self.files,
            self.bytes,
        }) catch unreachable;
        log(callbacks.log_context, .{ .level = .function, .message = message });
    }
};

pub fn capture(owner: *Owner, io: std.Io) ![32]u8 {
    var progress: Progress = .{
        .owner = owner,
        .io = io,
        .reported = std.Io.Clock.awake.now(io),
    };
    const callbacks = owner.configuration.callbacks;
    if (callbacks.log) |log|
        log(
            callbacks.log_context,
            .{
                .level = .function,
                .message = "Checking package databases",
            },
        );
    var arena = std.heap.ArenaAllocator.init(owner.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hash = Hash.init(.{});
    for ([_][]const u8{ "local", "sync" }) |name| {
        try owner.checkCancelled();
        const path = try std.fmt.allocPrint(a, "{s}{s}", .{ owner.configuration.database_path, name });
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) return err;
            field(&hash, name);
            field(&hash, "missing");
            continue;
        };
        defer dir.close(io);
        field(&hash, name);
        field(&hash, "present");
        var paths: std.ArrayList([]const u8) = .empty;
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            try owner.checkCancelled();
            try paths.append(a, try a.dupe(u8, entry.path));
            progress.report(false);
        }
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        for (paths.items) |file_path| {
            try owner.checkCancelled();
            field(&hash, file_path);
            const link_stat = try dir.statFile(io, file_path, .{ .follow_symlinks = false });
            const stat = if (link_stat.kind == .sym_link)
                try dir.statFile(
                    io,
                    file_path,
                    .{ .follow_symlinks = true },
                )
            else
                link_stat;
            // Walker intentionally does not follow directory links. Refuse an
            // incomplete fingerprint rather than omitting their descendants.
            if (link_stat.kind == .sym_link and stat.kind == .directory) return error.InvalidDatabaseEntry;
            field(&hash, @tagName(stat.kind));
            if (stat.kind == .directory) continue;
            if (stat.kind != .file) return error.InvalidDatabaseEntry;
            const file = try dir.openFile(io, file_path, .{});
            defer file.close(io);
            const initial = try file.stat(io);
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, initial.size, .little);
            hash.update(&length);
            var remaining = initial.size;
            var buffer: [64 * 1024]u8 = undefined;
            while (remaining != 0) {
                try owner.checkCancelled();
                const n = file.readStreaming(io, &.{buffer[0..@min(remaining, buffer.len)]}) catch |err| switch (err) {
                    error.EndOfStream => return error.StaleDatabaseState,
                    else => return err,
                };
                if (n == 0) return error.StaleDatabaseState;
                hash.update(buffer[0..n]);
                remaining -= n;
                progress.bytes +|= n;
                progress.report(false);
            }
            const final = try file.stat(io);
            if (initial.size != final.size or !std.meta.eql(initial.mtime, final.mtime) or
                !std.meta.eql(initial.ctime, final.ctime))
                return error.StaleDatabaseState;
            progress.files += 1;
            progress.report(false);
        }
    }
    progress.report(true);
    return hash.finalResult();
}

fn field(hash: *Hash, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hash.update(&length);
    hash.update(bytes);
}
