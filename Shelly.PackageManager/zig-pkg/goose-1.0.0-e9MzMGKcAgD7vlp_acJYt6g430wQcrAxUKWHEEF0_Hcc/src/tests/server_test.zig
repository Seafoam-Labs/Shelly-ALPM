const std = @import("std");
const goose = @import("goose");
const Connection = goose.Connection;
const signal = goose.signal;
const GStr = goose.core.value.GStr;

const MyInterface = struct {
    conn: *Connection,
    ThisIsAProps: goose.Property(i32, .ReadWrite) = goose.property(i32, .ReadWrite, 43),
    thisIsAsignal: goose.Signal(GStr) = signal("thisIsAsignal", GStr),

    pub const INTERFACE_NAME = "dev.myinterface.test";

    pub fn init(conn: *Connection, _: void) @This() {
        return MyInterface{
            .conn = conn,
        };
    }

    pub fn Testing(self: *MyInterface) !GStr {
        std.debug.print("MyInterface.Testing called!\n", .{});
        std.debug.print("Prop value: {d}\n", .{self.ThisIsAProps.value});
        try self.thisIsAsignal.trigger(self.conn, GStr.new("from the random Signal"));
        return GStr.new("Hello");
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("Initializing connection...\n", .{});
    // NOTE: This requires a running DBus session bus.
    var conn = try Connection.init(allocator, .Session, init.io, init.environ_map);
    defer conn.close();

    std.debug.print("Registering interface {s}...\n", .{MyInterface.INTERFACE_NAME});
    const handle = try conn.registerObject(MyInterface, "dev.myinterface.test", "/dev/myinterface/test", {});

    std.debug.print("Service registered. Handle: {d}\n", .{handle});
    std.debug.print("Ready to serve requests.\n", .{});

    // Uncomment to run loop:
    try conn.waitOnHandle(handle);
}
