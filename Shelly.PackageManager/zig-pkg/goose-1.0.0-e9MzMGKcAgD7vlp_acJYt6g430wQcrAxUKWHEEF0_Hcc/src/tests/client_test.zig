const std = @import("std");
const goose = @import("goose");
const proxy = goose.proxy;
const GStr = goose.core.value.GStr;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var conn = try goose.Connection.init(
        allocator,
        .Session,
        init.io,
        init.environ_map,
    );
    defer conn.close();

    try conn.addMatch("type='signal',interface='dev.myinterface.test'");

    const Handler = struct {
        fn onSignal(_: ?*anyopaque, msg: goose.core.Message) void {
            var iface: []const u8 = "unknown";
            var member: []const u8 = "unknown";
            for (msg.header.header_fields) |f| {
                switch (f.value) {
                    .Interface => |s| iface = s,
                    .Member => |s| member = s,
                    else => {},
                }
            }
            std.debug.print("CLIENT RECEIVED SIGNAL: {s}.{s}\n", .{ iface, member });
        }
    };
    try conn.registerSignalHandler("dev.myinterface.test", "thisIsAsignal", Handler.onSignal, null);

    const p = proxy.Proxy.init(&conn, "dev.myinterface.test", "/dev/myinterface/test", "dev.myinterface.test");

    // Test Introspection
    std.debug.print("Client: Calling Introspect()...\n", .{});
    var intro_res = try p.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
    defer intro_res.deinit();
    const xml = try intro_res.expect(GStr);
    std.debug.print("Client: Introspection XML:\n{s}\n", .{xml.s});

    std.debug.print("Client: Calling Testing()...\n", .{});
    var result = try p.call("Testing", .{});
    defer result.deinit();

    const s = try result.expect(GStr);
    std.debug.print("Client: Result: {s}\n", .{s.s});
}
