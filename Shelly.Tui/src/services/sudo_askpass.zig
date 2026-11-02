//! One-shot password channel for sudo -A, independent of Shelly's stdin protocol.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const socket_environment = "SHELLY_TUI_ASKPASS_SOCKET";
const max_password = 4096;

pub const Broker = struct {
    allocator: Allocator,
    io: Io,
    directory: []u8,
    socket_path: []u8,
    password: []u8,
    server: Io.net.Server,
    task: ?Io.Future(void) = null,

    pub fn start(allocator: Allocator, io: Io, password: []const u8) !*Broker {
        if (password.len == 0 or password.len > max_password or std.mem.indexOfAny(u8, password, "\r\n\x00") != null)
            return error.InvalidPassword;
        const self = try allocator.create(Broker);
        errdefer allocator.destroy(self);
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const directory = try std.fmt.allocPrint(allocator, "/tmp/shelly-tui-auth-{s}", .{std.fmt.bytesToHex(random, .lower)});
        errdefer allocator.free(directory);
        try Io.Dir.cwd().createDir(io, directory, .fromMode(0o700));
        errdefer Io.Dir.cwd().deleteDir(io, directory) catch {};
        const socket_path = try std.fs.path.join(allocator, &.{ directory, "askpass" });
        errdefer allocator.free(socket_path);
        const owned_password = try allocator.dupe(u8, password);
        errdefer {
            std.crypto.secureZero(u8, owned_password);
            allocator.free(owned_password);
        }
        const address = try Io.net.UnixAddress.init(socket_path);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        errdefer Io.Dir.cwd().deleteFile(io, socket_path) catch {};
        self.* = .{ .allocator = allocator, .io = io, .directory = directory, .socket_path = socket_path, .password = owned_password, .server = server };
        self.task = try Io.concurrent(io, serve, .{self});
        return self;
    }

    fn serve(self: *Broker) void {
        var used = false;
        while (true) {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            // Wrong passwords must fail instead of resending a retained credential on retry.
            if (used) continue;
            used = true;
            defer std.crypto.secureZero(u8, self.password);
            var buffer: [512]u8 = undefined;
            defer std.crypto.secureZero(u8, &buffer);
            var writer = stream.writer(self.io, &buffer);
            writer.interface.writeAll(self.password) catch return;
            writer.interface.writeByte('\n') catch return;
            writer.interface.flush() catch return;
        }
    }

    pub fn environment(self: *const Broker, original: *const std.process.Environ.Map) !std.process.Environ.Map {
        var env = try original.clone(self.allocator);
        errdefer env.deinit();
        const executable = try std.process.executablePathAlloc(self.io, self.allocator);
        defer self.allocator.free(executable);
        try env.put("SUDO_ASKPASS", executable);
        try env.put(socket_environment, self.socket_path);
        return env;
    }

    pub fn deinit(self: *Broker) void {
        if (self.task) |*task| task.cancel(self.io);
        self.server.deinit(self.io);
        Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
        Io.Dir.cwd().deleteDir(self.io, self.directory) catch {};
        std.crypto.secureZero(u8, self.password);
        self.allocator.free(self.password);
        self.allocator.free(self.socket_path);
        self.allocator.free(self.directory);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub fn respond(io: Io, socket_path: []const u8) !void {
    const address = try Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var read_buffer: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var reader = stream.reader(io, &read_buffer);
    var password: [max_password + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &password);
    const len = try reader.interface.readSliceShort(&password);
    if (len < 2 or len > max_password + 1 or password[len - 1] != '\n') return error.AuthenticationUnavailable;
    var stdout_buffer: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &stdout_buffer);
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout.interface.writeAll(password[0..len]);
    try stdout.interface.flush();
}

test "askpass broker is private one-shot and removes its endpoint" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const broker = try Broker.start(alloc, io, "fixture-secret");
    var owned = true;
    defer if (owned) broker.deinit();
    const directory = try alloc.dupe(u8, broker.directory);
    defer alloc.free(directory);
    const stat = try Io.Dir.cwd().statFile(io, directory, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    const address = try Io.net.UnixAddress.init(broker.socket_path);
    for ([_][]const u8{ "fixture-secret\n", "" }) |expected| {
        const client = try address.connect(io);
        defer client.close(io);
        var buffer: [128]u8 = undefined;
        var reader = client.reader(io, &buffer);
        const result = try reader.interface.allocRemaining(alloc, .limited(4096));
        defer alloc.free(result);
        try std.testing.expectEqualStrings(expected, result);
    }
    try std.testing.expect(std.mem.allEqual(u8, broker.password, 0));
    broker.deinit();
    owned = false;
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, directory, .{}));
}

test "unused askpass broker cancels when credentials are cached" {
    const broker = try Broker.start(std.testing.allocator, std.testing.io, "unused-secret");
    broker.deinit();
}

test "askpass environment contains endpoint metadata but no password" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    const broker = try Broker.start(std.testing.allocator, std.testing.io, "fixture-secret");
    defer broker.deinit();
    var child_env = try broker.environment(&env);
    defer child_env.deinit();
    try std.testing.expect(env.get(socket_environment) == null);
    try std.testing.expect(std.fs.path.isAbsolute(child_env.get("SUDO_ASKPASS").?));
    try std.testing.expectEqualStrings(broker.socket_path, child_env.get(socket_environment).?);
    var entries = child_env.iterator();
    while (entries.next()) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.value_ptr.*, "fixture-secret") == null);
}
