//! Opt-in disposable-root benchmark. No host package state or scriptlets.
//! Run the same binary with RLPM_PAYLOAD_BENCH_MODE=immediate or batched.
const std = @import("std");
const builtin = @import("builtin");
const rlpm = @import("Shelly_Rlpm");
const Fixture = @import("actions_fixture.zig");
const Archive = @import("archive_fixture.zig");

const E = rlpm.Transaction.Executor;
const c = @cImport({
    @cInclude("stdlib.h");
});
const a = std.testing.allocator;
const io = std.testing.io;

fn setting(name: [:0]const u8, fallback: []const u8) []const u8 {
    return if (c.getenv(name)) |value| std.mem.span(value) else fallback;
}

fn commit(
    owner: *rlpm.Owner,
    path: ?[]const u8,
    mode: []const u8,
    workload: []const u8,
    operation: []const u8,
    repetition: usize,
    count: usize,
) !void {
    const tx = try owner.initializeTransaction(
        io,
        .{
            .no_hooks = true,
            .no_scriptlets = true,
            .no_dependencies = true,
        },
    );
    defer owner.releaseTransaction() catch unreachable;
    if (path) |archive| try Fixture.add(tx, archive) else try tx.remove("payload-bench");
    try tx.prepare();
    const started = std.Io.Clock.awake.now(io);
    try tx.commit();
    const elapsed = started.untilNow(io, .awake).toMilliseconds();
    std.debug.print(
        "payload-bench,{s},{s},{s},{s},{d},{d},{d},{d},{d},{d},{d}\n",
        .{
            @tagName(builtin.mode),
            mode,
            workload,
            operation,
            repetition,
            if (count == 0)
                tx.manifest().?.entries.items.len
            else
                count,
            elapsed,
            tx.execution.payload_work_ms,
            tx.execution.payload_sync_ms,
            tx.execution.database_publish_ms,
            tx.execution.payload_sync_targets,
        },
    );
}

test "payload durability benchmark" {
    const mode = setting("RLPM_PAYLOAD_BENCH_MODE", "batched");
    if (!std.mem.eql(u8, mode, "batched") and !std.mem.eql(u8, mode, "immediate"))
        return error.InvalidBenchmarkMode;
    E.test_immediate_payload_sync = std.mem.eql(u8, mode, "immediate");
    defer E.test_immediate_payload_sync = false;
    if (c.getenv("RLPM_PAYLOAD_BENCH_ARCHIVE")) |archive| {
        const runs = try std.fmt.parseInt(usize, setting("RLPM_PAYLOAD_BENCH_RUNS", "3"), 10);
        if (runs == 0 or runs > 20) return error.InvalidBenchmarkSize;
        for (0..runs) |run| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            var owner = try fixture.owner();
            defer owner.deinit() catch unreachable;
            try commit(&owner, std.mem.span(archive), mode, "real-archive", "install", run + 1, 0);
        }
        return;
    }
    const workload = setting("RLPM_PAYLOAD_BENCH_WORKLOAD", "headers");
    const large = std.mem.eql(u8, workload, "large");
    if (!large and !std.mem.eql(u8, workload, "headers")) return error.InvalidWorkload;
    const count = try std.fmt.parseInt(
        usize,
        setting("RLPM_PAYLOAD_BENCH_FILES", if (large) "4" else "10000"),
        10,
    );
    const runs = try std.fmt.parseInt(usize, setting("RLPM_PAYLOAD_BENCH_RUNS", "3"), 10);
    if (count == 0 or count > 100000 or runs == 0 or runs > 20) return error.InvalidBenchmarkSize;
    const content = try a.alloc(u8, if (large) 8 * 1024 * 1024 else 256);
    defer a.free(content);
    // Deterministic nonzero contents; compression/CoW settings must be recorded.
    for (content, 0..) |*byte, i|
        byte.* = @truncate(i *% 37 +% (i >> 9));
    const entries = try a.alloc(Archive.Entry, count + 1);
    defer a.free(entries);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name|
            a.free(name);
        names.deinit(a);
    }
    for (entries[1..], 0..) |*entry, i| {
        const name = try std.fmt.allocPrint(a, "usr/include/bench/{d}/header-{d}.h", .{ i / 100, i });
        try names.append(a, name);
        entry.* = .{ .path = name, .contents = content };
    }
    entries[0] = .{ .path = ".PKGINFO", .contents = "pkgname = payload-bench\npkgver = 1-1\narch = any\n" };
    var first = try Archive.init(entries, .none);
    defer first.deinit();
    entries[0].contents = "pkgname = payload-bench\npkgver = 2-1\narch = any\n";
    var second = try Archive.init(entries, .none);
    defer second.deinit();
    std.debug.print(
        "kind,build,mode,workload,operation,run,files,total_ms,payload_ms,sync_ms,database_publish_ms,sync_targets\n",
        .{},
    );
    for (0..runs) |run| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var owner = try fixture.owner();
        defer owner.deinit() catch unreachable;
        try commit(&owner, first.path, mode, workload, "install", run + 1, count);
        try commit(&owner, second.path, mode, workload, "upgrade", run + 1, count);
        try commit(&owner, null, mode, workload, "remove", run + 1, count);
    }
}
