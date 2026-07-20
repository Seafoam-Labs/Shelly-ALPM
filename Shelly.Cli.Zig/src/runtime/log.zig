const std = @import("std");

const log_path = "/var/log/shelly.log";
const rotated_log_path = "/var/log/shelly.log.1";
const max_log_size = 5 * 1024 * 1024;

pub const SessionLog = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64,

    pub fn tryOpen(io: std.Io) ?SessionLog {
        return tryOpenAt(io, log_path, rotated_log_path);
    }

    pub fn tryOpenAt(io: std.Io, path: []const u8, rotated_path: []const u8) ?SessionLog {
        rotateIfNeeded(io, path, rotated_path);
        const file = std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
        }) catch return null;
        const stat = file.stat(io) catch {
            file.close(io);
            return null;
        };
        return .{ .io = io, .file = file, .offset = stat.size };
    }

    pub fn close(self: *SessionLog) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn writeSessionHeader(
        self: *SessionLog,
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) void {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
        buffer.writer.writeAll("=====================================\n") catch return;
        buffer.writer.print("[{d}] SESSION START\n", .{timestamp}) catch return;
        buffer.writer.print("[{d}] Command: shelly", .{timestamp}) catch return;
        for (arguments) |argument| buffer.writer.print(" {s}", .{argument}) catch return;
        buffer.writer.writeAll("\n=====================================\n") catch return;
        self.append(buffer.writer.buffered());
    }

    pub fn writeSessionFooter(
        self: *SessionLog,
        allocator: std.mem.Allocator,
        exit_code: u8,
    ) void {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
        buffer.writer.print(
            "[{d}] SESSION END — exit code: {d}\n",
            .{ timestamp, exit_code },
        ) catch return;
        self.append(buffer.writer.buffered());
    }

    fn append(self: *SessionLog, bytes: []const u8) void {
        self.file.writePositionalAll(self.io, bytes, self.offset) catch return;
        self.offset += bytes.len;
    }
};

fn rotateIfNeeded(io: std.Io, path: []const u8, rotated_path: []const u8) void {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    const stat = file.stat(io) catch {
        file.close(io);
        return;
    };
    file.close(io);
    if (stat.size < max_log_size) return;
    std.Io.Dir.deleteFileAbsolute(io, rotated_path) catch {};
    std.Io.Dir.renameAbsolute(path, rotated_path, io) catch {};
}

test "writes a complete session to an injected log path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/shelly.log",
        .{absolute_buffer[0..absolute_length]},
    );
    defer allocator.free(path);
    const rotated_path = try std.fmt.allocPrint(allocator, "{s}.1", .{path});
    defer allocator.free(rotated_path);

    var session = SessionLog.tryOpenAt(std.testing.io, path, rotated_path) orelse
        return error.CouldNotOpenTestLog;
    session.writeSessionHeader(allocator, &.{ "query", "firefox" });
    session.writeSessionFooter(allocator, 7);
    session.close();

    const contents = try temporary.dir.readFileAlloc(
        std.testing.io,
        "shelly.log",
        allocator,
        .limited(4096),
    );
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Command: shelly query firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "SESSION END — exit code: 7") != null);
}
