//! Native-format transaction audit records; logging failure is diagnostic and
//! never turns successful package publication into a false rollback claim.
const std = @import("std");
const Tx = @import("Transaction.zig");
const Diagnostic = @import("Diagnostic.zig");

const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("time.h");
    @cInclude("syslog.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub fn log(tx: *Tx, comptime fmt: []const u8, args: anytype) void {
    write(tx, fmt, args) catch |err| {
        if (tx.owned_manifest) |*m| m.warnings.append(m.arena.allocator(), .{ .cause = err }) catch {};
        tx.owner.transactionEvent(
            .{ .diagnostic = Diagnostic.init(.transaction, err, null) },
        );
    };
}

fn write(tx: *Tx, comptime fmt: []const u8, args: anytype) !void {
    const options = tx.owner.configuration;
    if (options.log_file == null and !options.use_syslog) return;
    const a = tx.owner.allocator;
    const message = try std.fmt.allocPrintSentinel(a, fmt, args, 0);
    defer a.free(message);
    if (options.use_syslog) c.syslog(c.LOG_WARNING, "%s", message.ptr);
    if (options.log_file) |file_path| {
        const path = try a.dupeSentinel(u8, file_path, 0);
        defer a.free(path);
        const fd = c.open(path, c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd < 0) return error.AuditLogFailed;
        defer _ = c.close(fd);
        var now: c.time_t = @intCast(std.Io.Clock.real.now(tx.io).toSeconds());
        var local: c.struct_tm = undefined;
        if (c.localtime_r(&now, &local) == null) return error.AuditLogFailed;
        var stamp: [64]u8 = undefined;
        const count = c.strftime(&stamp, stamp.len, "%Y-%m-%dT%H:%M:%S%z", &local);
        if (count == 0) return error.AuditLogFailed;
        const line = try std.fmt.allocPrint(a, "[{s}] [ALPM] {s}\n", .{ stamp[0..count], message });
        defer a.free(line);
        var offset: usize = 0;
        while (offset < line.len) {
            const n = c.write(fd, line.ptr + offset, line.len - offset);
            if (n <= 0) return error.AuditLogFailed;
            offset += @intCast(n);
        }
    }
}
