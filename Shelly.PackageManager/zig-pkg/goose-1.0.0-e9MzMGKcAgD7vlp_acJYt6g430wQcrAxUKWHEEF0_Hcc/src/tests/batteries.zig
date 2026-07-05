const goose = @import("goose");
const proxy = goose.proxy;
const GStr = goose.core.value.GStr;

pub const PropertiesProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) PropertiesProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties") };
    }

    pub fn Get(self: PropertiesProxy, interface_name: GStr, property_name: GStr) !proxy.MethodResult {
        const res = try self.inner.call("Get", .{ interface_name, property_name });
        return res;
    }
    pub fn GetAll(self: PropertiesProxy, interface_name: GStr) !proxy.MethodResult {
        const res = try self.inner.call("GetAll", .{interface_name});
        return res;
    }
    pub fn Set(self: PropertiesProxy, interface_name: GStr, property_name: GStr, value: anytype) !void {
        var res = try self.inner.call("Set", .{ interface_name, property_name, value });
        res.deinit();
    }
};

pub const IntrospectableProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) IntrospectableProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Introspectable") };
    }

    pub fn Introspect(self: IntrospectableProxy) !GStr {
        var res = try self.inner.call("Introspect", .{});
        return res.expect(GStr);
    }
};

pub const PeerProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) PeerProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Peer") };
    }

    pub fn Ping(self: PeerProxy) !void {
        var res = try self.inner.call("Ping", .{});
        res.deinit();
    }
    pub fn GetMachineId(self: PeerProxy) !GStr {
        var res = try self.inner.call("GetMachineId", .{});
        return res.expect(GStr);
    }
};

pub const UPowerProxy = struct {
    inner: proxy.Proxy,

    pub fn init(conn: *goose.Connection) UPowerProxy {
        return .{ .inner = proxy.Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower") };
    }

    pub fn EnumerateDevices(self: UPowerProxy) !proxy.MethodResult {
        const res = try self.inner.call("EnumerateDevices", .{});
        return res;
    }
    pub fn EnumerateKbdBacklights(self: UPowerProxy) !proxy.MethodResult {
        const res = try self.inner.call("EnumerateKbdBacklights", .{});
        return res;
    }
    pub fn GetDisplayDevice(self: UPowerProxy) !proxy.MethodResult {
        const res = try self.inner.call("GetDisplayDevice", .{});
        return res;
    }
    pub fn GetCriticalAction(self: UPowerProxy) !GStr {
        var res = try self.inner.call("GetCriticalAction", .{});
        return res.expect(GStr);
    }
};
