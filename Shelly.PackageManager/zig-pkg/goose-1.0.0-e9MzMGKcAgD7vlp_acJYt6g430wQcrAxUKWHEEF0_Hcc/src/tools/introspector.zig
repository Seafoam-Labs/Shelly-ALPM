const std = @import("std");
const goose = @import("goose");
const proxy = goose.proxy;
const message = goose.message;
const GStr = goose.core.value.GStr;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());

    const prog_path = args.next() orelse "introspector";
    const prog_name = std.fs.path.basename(prog_path);

    const dest_arg = args.next();
    const path_arg = args.next();
    const bustype_arg = args.next();

    if (dest_arg == null or path_arg == null or bustype_arg == null) {
        std.debug.print("Usage: {s} <destination> <object_path> <bus_type>\n", .{prog_name});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  <destination>  The well-known name of the service (e.g. org.freedesktop.DBus)\n", .{});
        std.debug.print("  <object_path>  The object path to introspect (e.g. /org/freedesktop/DBus)\n", .{});
        std.debug.print("  <bus_type>     The bus to connect to: 'Session' or 'System'\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} org.freedesktop.DBus /org/freedesktop/DBus Session\n", .{prog_name});
        return;
    }

    const dest = dest_arg.?;
    const path = path_arg.?;
    const bustype_string = bustype_arg.?;
    const bustype = std.meta.stringToEnum(goose.BusType, bustype_string).?;

    var conn = try goose.Connection.init(allocator, bustype, init.io, init.environ_map);
    defer conn.close();

    std.debug.print("Target: {s} {s}\n", .{ dest, path });

    const dbus_proxy = proxy.Proxy.init(&conn, dest, path, "org.freedesktop.DBus.Introspectable");

    var result = dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{}) catch |err| {
        std.debug.print("Error calling Introspect: {}\n", .{err});
        return;
    };
    defer result.deinit();

    const xml = try result.expect(GStr);

    const node = try goose.introspection.parse(allocator, xml.s);
    defer node.deinit(allocator);

    std.debug.print("Found {d} interfaces.\n", .{node.interfaces.len});
    for (node.interfaces) |iface| {
        std.debug.print("\nInterface: {s}\n", .{iface.name});
        for (iface.methods) |m| {
            std.debug.print("  Method: {s}(", .{m.name});
            for (m.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(", ", .{});
                if (arg.name.len > 0) {
                    std.debug.print("{s}: {s}", .{ arg.name, arg.type });
                } else {
                    std.debug.print("{s}", .{arg.type});
                }
            }
            std.debug.print(")\n", .{});
        }
    }

    if (node.children.len > 0) {
        std.debug.print("\nChild nodes:\n", .{});
        for (node.children) |child| {
            std.debug.print(" - {s}\n", .{child.name});
        }
    }
}
