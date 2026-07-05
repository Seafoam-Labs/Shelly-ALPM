const std = @import("std");
const core = @import("core.zig");
const message = @import("message_utils.zig");
const Connection = @import("root.zig").Connection;
const BodyEncoder = message.BodyEncoder;
const BodyDecoder = message.BodyDecoder;
const GStr = core.value.GStr;

/// Result of a D-Bus method call.
/// Owns the reply message and provides methods to decode its body.
pub const MethodResult = struct {
    msg: core.Message,
    conn: *Connection,
    arena: std.heap.ArenaAllocator,

    /// Releases resources associated with the result message.
    pub fn deinit(self: *MethodResult) void {
        self.conn.freeMessage(&self.msg);
        self.arena.deinit();
    }

    /// Returns a BodyDecoder to read the result body.
    /// Note: The decoder's lifetime is tied to the result.
    pub fn reader(self: *MethodResult) BodyDecoder {
        return BodyDecoder.fromMessage(self.arena.allocator(), self.msg);
    }

    /// Convenience method to decode a single value of type T from the reply body.
    /// Note: The MethodResult must still be explicitly deinitialized after use
    /// if T borrows memory (like strings or slices) from the message body.
    pub fn expect(self: *MethodResult, comptime T: type) !T {
        var dec = self.reader();
        return try dec.decode(T);
    }
};

/// A local representation of a remote D-Bus object.
pub const Proxy = struct {
    conn: *Connection,
    dest: [:0]const u8,
    path: [:0]const u8,
    interface: [:0]const u8,

    /// Creates a new Proxy for a remote object.
    /// `dest`: The well-known name or unique name of the destination connection.
    /// `path`: The object path on the destination.
    /// `interface`: The default interface to use for method calls.
    pub fn init(conn: *Connection, dest: [:0]const u8, path: [:0]const u8, interface: [:0]const u8) Proxy {
        return .{
            .conn = conn,
            .dest = dest,
            .path = path,
            .interface = interface,
        };
    }

    /// Performs a low-level method call on a specific interface.
    pub fn rawCall(self: Proxy, iface: [:0]const u8, method: [:0]const u8, args: anytype) !MethodResult {
        var encoder = try BodyEncoder.encode(self.conn.__allocator, args);
        defer encoder.deinit();

        const reply = try self.conn.methodCall(
            self.dest,
            self.path,
            iface,
            method,
            encoder.signature(),
            encoder.body(),
        );

        if (reply.isError()) {
            const err_name = reply.getErrorName() orelse "UnknownError";
            var decoder = BodyDecoder.fromMessage(self.conn.__allocator, reply);
            const err_msg = decoder.decode(GStr) catch GStr.new("(no error message)");
            std.debug.print("[goose] DBus Error: {s}: {s}\n", .{ err_name, err_msg.s });
            self.conn.freeMessage(@constCast(&reply));
            return error.RemoteError;
        }

        return MethodResult{
            .msg = reply,
            .conn = self.conn,
            .arena = std.heap.ArenaAllocator.init(self.conn.__allocator),
        };
    }

    /// Invokes a method on the remote object using the default interface.
    /// `args` can be a single value or a tuple of values.
    /// Returns a MethodResult owning the reply message.
    pub fn call(self: Proxy, method: [:0]const u8, args: anytype) !MethodResult {
        return self.rawCall(self.interface, method, args);
    }

    /// Helper to get a property value.
    /// T must be a union (Variant) that can hold the expected property type.
    /// D-Bus Get returns a Variant ('v').
    /// The returned value is allocated using the connection's allocator if it contains strings or slices.
    pub fn getProperty(self: Proxy, comptime T: type, name: [:0]const u8) !T {
        var result = try self.rawCall("org.freedesktop.DBus.Properties", "Get", .{ GStr.new(self.interface), GStr.new(name) });
        defer result.deinit();
        var dec = BodyDecoder.fromMessage(self.conn.__allocator, result.msg);
        return try dec.decodeAlloc(T);
    }

    /// Helper to set a property value.
    /// `value` must be a union (Variant) representing the new value.
    pub fn setProperty(self: Proxy, name: [:0]const u8, value: anytype) !void {
        var result = try self.rawCall("org.freedesktop.DBus.Properties", "Set", .{ GStr.new(self.interface), GStr.new(name), value });
        result.deinit();
    }
};
