const std = @import("std");

const goose = @import("goose");
const core = goose.core;
const message = goose.message;
const proxy = goose.proxy;
const Value = core.value.Value;
const GStr = core.value.GStr;
const GPath = core.value.GPath;
const Connection = goose.Connection;

const UPowerProxy = @import("batteries.zig").UPowerProxy;

fn printData(data: []const u8) void {
    for (data) |x| {
        if ((x >= 46 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122)) {
            std.debug.print("{c}", .{x});
        } else {
            std.debug.print("\\{o}", .{x});
        }
    }
    std.debug.print("\n", .{});
}

// Signal handler callback
// fn onPropertiesChanged(ctx: ?*anyopaque, msg: core.Message) void {
//     const allocator: std.mem.Allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(ctx orelse return))).*;
//
//     const PropValue = union(enum) {
//         String: GStr,
//         Bool: bool,
//         Uint32: u32,
//         Int32: i32,
//         Double: f64,
//     };
//     const ChangedProp = struct { key: GStr, value: PropValue };
//
//     var decoder = message.BodyDecoder.fromMessage(allocator, msg);
//
//     const interface_name = decoder.decode(GStr) catch return;
//     const changed_props = decoder.decode([]const ChangedProp) catch return;
//     defer allocator.free(changed_props);
//     const invalidated_props = decoder.decode([]const GStr) catch return;
//     defer allocator.free(invalidated_props);
//
//     std.debug.print("SIGNAL [Callback]: PropertiesChanged on interface '{s}'\n", .{interface_name.s});
//     for (changed_props) |prop| {
//         std.debug.print(" - Changed: {s} = ", .{prop.key.s});
//         switch (prop.value) {
//             .String => |s| std.debug.print("'{s}'\n", .{s.s}),
//             .Bool => |b| std.debug.print("{}\n", .{b}),
//             .Uint32 => |u| std.debug.print("{d}\n", .{u}),
//             .Int32 => |i| std.debug.print("{d}\n", .{i}),
//             .Double => |d| std.debug.print("{d}\n", .{d}),
//         }
//     }
// }

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var conn = try Connection.init(allocator, .Session, init.io, init.environ_map);
    defer conn.close();

    // Example 1: Call GetId (no args, returns string)
    {
        std.debug.print("Calling GetId...\n", .{});
        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetId",
            null,
            &.{},
        );
        defer conn.freeMessage(&reply);

        // Read response
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const id = try decoder.decode(GStr);
        std.debug.print("Bus ID: {s}\n", .{id.s});
    }

    // Example 2: Call NameHasOwner (takes string, returns bool)
    {
        std.debug.print("\nCalling NameHasOwner...\n", .{});
        var encoder = try message.BodyEncoder.encode(allocator, GStr.new("org.freedesktop.DBus"));
        defer encoder.deinit();

        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            encoder.signature(),
            encoder.body(),
        );
        defer conn.freeMessage(&reply);

        // Read response
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const exists = try decoder.decode(bool);
        std.debug.print("NameHasOwner('org.freedesktop.DBus'): {}\n", .{exists});
    }

    // Example 3: Call ListNames (returns array of strings)
    {
        std.debug.print("\nCalling ListNames...\n", .{});
        var reply = try conn.methodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            null,
            &.{},
        );
        defer conn.freeMessage(&reply);

        // Read response
        var decoder = message.BodyDecoder.fromMessage(allocator, reply);
        const names = try decoder.decode([]const GStr);
        defer allocator.free(names);

        std.debug.print("Found {d} names. First 5:\n", .{names.len});
        for (names[0..@min(5, names.len)]) |name| {
            std.debug.print(" - {s}\n", .{name.s});
        }
    }

    // Example 4: Manual Complex Type Test (Struct with Array and Dict)
    {
        std.debug.print("\nTesting Struct/Array/Dict Reading manually...\n", .{});

        const MyEntry = struct { key: GStr, value: i32 };
        const MyData = struct { id: i32, tags: []const GStr, scores: []const MyEntry };

        const entries = [_]MyEntry{ .{ .key = GStr.new("A"), .value = 10 }, .{ .key = GStr.new("B"), .value = 20 } };
        const tags = [_]GStr{ GStr.new("zig"), GStr.new("dbus") };
        const data = MyData{ .id = 42, .tags = &tags, .scores = &entries };

        // Use encode with a single complex argument
        var encoder = try message.BodyEncoder.encode(allocator, data);
        defer encoder.deinit();

        std.debug.print("Signature: {s}\n", .{encoder.signature()});

        var decoder = message.BodyDecoder.init(allocator, encoder.body(), encoder.signature(), .little);
        const decoded = try decoder.decode(MyData);
        defer {
            allocator.free(decoded.tags);
            allocator.free(decoded.scores);
        }

        std.debug.print("Decoded Struct:\n", .{});
        std.debug.print(" - ID: {d}\n", .{decoded.id});
        std.debug.print(" - Tags: {d} items\n", .{decoded.tags.len});
        std.debug.print(" - Scores: {d} entries\n", .{decoded.scores.len});
        for (decoded.scores) |e| {
            std.debug.print("   - {s} => {d}\n", .{ e.key.s, e.value });
        }
    }

    // Example 5: Using Proxy API
    {
        std.debug.print("\nTesting Proxy API...\n", .{});
        const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");

        // Call GetId via Proxy
        var result = try dbus_proxy.call("GetId", .{});
        defer result.deinit();
        const id = try result.expect(GStr);
        std.debug.print("Proxy GetId: {s}\n", .{id.s});

        // Call NameHasOwner via Proxy
        var result2 = try dbus_proxy.call("NameHasOwner", .{GStr.new("org.freedesktop.DBus")});
        defer result2.deinit();
        const has_owner = try result2.expect(bool);
        std.debug.print("Proxy NameHasOwner: {}\n", .{has_owner});
    }

    // Example 7: Error Handling Test
    {
        std.debug.print("\nTesting Proxy Error Handling (calling non-existent method)...\n", .{});
        const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");

        _ = dbus_proxy.call("ThisMethodDoesNotExist", .{}) catch |err| {
            std.debug.print("Caught expected error: {any}\n", .{err});
        };
    }

    // Example 8: Property Access Test
    {
        std.debug.print("\nTesting Property Access (Notifications Dnd)...\n", .{});
        const noti_proxy = proxy.Proxy.init(&conn, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications");

        const NotiProp = union(enum) { Bool: bool, String: GStr };
        const dnd = try noti_proxy.getProperty(NotiProp, "Dnd");
        std.debug.print("Notifications Dnd: {}\n", .{dnd.Bool});
    }

    // Example 9: Owned Decoding Test
    {
        std.debug.print("\nTesting Owned Decoding (decodeAlloc)...\n", .{});
        const dbus_proxy = proxy.Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
        var result = try dbus_proxy.call("GetId", .{});

        var decoder = result.reader();
        // Decode and copy string
        const owned_id = try decoder.decodeAlloc(GStr);

        // owned_id should still be valid
        std.debug.print("Owned Bus ID (after deinit): {s}\n", .{owned_id.s});

        // Free result immediately
        result.deinit();
    }

    // Example 6: Listening to Signals (Callback based)
    // {
    //     std.debug.print("\nListening to signals via Dispatcher... (Ctrl+C to quit)\n", .{});
    //     try conn.addMatch("type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'");
    //
    //     // Register our callback
    //     try conn.registerSignalHandler("org.freedesktop.DBus.Properties", "PropertiesChanged", onPropertiesChanged, @ptrCast(@constCast(&allocator)));
    //
    //     while (true) {
    //         var msg = try conn.waitMessage();
    //         defer conn.freeMessage(&msg);
    //         // waitMessage automatically dispatches registered handlers.
    //         // Other messages (like NameAcquired) will be returned here and printed by waitMessage debug.
    //     }
    // }

    // Example 7: Using Generated proxy
    {
        var conn2 = try Connection.init(allocator, .System);
        defer conn2.close();

        const power = UPowerProxy.init(&conn2);
        var answer = try power.EnumerateDevices();
        defer answer.deinit();
        printData(answer.msg.body);
        std.debug.print("{any}\n{any}\n", .{ answer.msg.header, answer.msg.body });
        const paths = try answer.expect([]const GPath);

        for (paths) |path| {
            std.debug.print("{s}\n", .{path.s});
        }
    }
}
