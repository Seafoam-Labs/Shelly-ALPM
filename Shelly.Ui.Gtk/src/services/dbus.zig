const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const gobject = bindings.gobject;
const glib = bindings.glib;

const TrayPath: [:0]const u8 = "/org/shellyorg/Notifications";
const TrayInterface: [:0]const u8 = "com.shellyorg.shelly";

const POLKIT_NAME: [:0]const u8 = "org.freedesktop.PolicyKit1";
const POLKIT_AUTH_PATH: [:0]const u8 = "/org/freedesktop/PolicyKit1/Authority";
const POLKIT_AUTH_IFACE: [:0]const u8 = "org.freedesktop.PolicyKit1.Authority";
const PROBE_PATH: [:0]const u8 = "/org/shelly/AuthAgentProbe";

const LOGIND_NAME: [:0]const u8 = "org.freedesktop.login1";
const LOGIND_PATH: [:0]const u8 = "/org/freedesktop/login1";
const LOGIND_MANAGER_IFACE: [:0]const u8 = "org.freedesktop.login1.Manager";

pub const PolkitStatus = enum {
    ready,
    no_daemon,
    no_agent,
    unknown,
};

pub const DBus = struct {
    connection: ?*gio.DBusConnection = null,
    system_connection: ?*gio.DBusConnection = null,

    pub fn deinit(self: *DBus) void {
        if (self.connection) |c| c.unref();
        if (self.system_connection) |c| c.unref();
    }

    pub fn updatesMadeInUi(self: *DBus) void {
        self.emitTray("Refresh");
    }

    fn ensureBus(self: *DBus, slot: *?*gio.DBusConnection, bus: gio.BusType) ?*gio.DBusConnection {
        _ = self;
        if (slot.*) |conn| return conn;
        var err: ?*glib.Error = null;
        const conn = gio.busGetSync(bus, null, &err);
        if (err) |e| {
            std.log.warn("bus_get_sync failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return null;
        }
        slot.* = conn;
        return conn;
    }

    fn ensureConnection(self: *DBus) ?*gio.DBusConnection {
        return self.ensureBus(&self.connection, .session);
    }

    fn ensureSystemConnection(self: *DBus) ?*gio.DBusConnection {
        return self.ensureBus(&self.system_connection, .system);
    }

    fn emitTray(self: *DBus, signal: [:0]const u8) void {
        const conn = self.ensureConnection() orelse return;
        var err: ?*glib.Error = null;
        _ = gio.DBusConnection.emitSignal(
            conn,
            null,
            TrayPath,
            TrayInterface,
            signal,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("emit_signal failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
        }
    }

    pub fn checkPolkitStatus(self: *DBus) PolkitStatus {
        switch (self.polkitDaemonPresence()) {
            .absent => return .no_daemon,
            .unknown => return .unknown,
            .present => {},
        }
        return switch (self.authAgentPresent()) {
            .present => .ready,
            .absent => .no_agent,
            .unknown => .unknown,
        };
    }

    pub fn polkitAvailable(self: *DBus) bool {
        return self.polkitDaemonPresence() == .present;
    }

    const DaemonPresence = enum { present, absent, unknown };

    fn polkitDaemonPresence(self: *DBus) DaemonPresence {
        const conn = self.ensureSystemConnection() orelse return .unknown;
        const params = glib.Variant.new("(s)", POLKIT_NAME.ptr);
        const reply_type = glib.VariantType.new("(b)");
        defer reply_type.free();
        var call_err: ?*glib.Error = null;
        const result = conn.callSync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            params,
            reply_type,
            .{},
            -1,
            null,
            &call_err,
        );
        if (call_err) |e| {
            std.log.info("NameHasOwner(PolicyKit1) failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return .unknown;
        }
        const res = result orelse return .unknown;
        defer res.unref();
        const child = res.getChildValue(0);
        defer child.unref();
        std.log.debug("NameHasOwner(PolicyKit1) = {}", .{child.getBoolean()});
        return if (child.getBoolean() != 0) .present else .absent;
    }

    const AgentPresence = enum { present, absent, unknown };

    fn authAgentPresent(self: *DBus) AgentPresence {
        const conn = self.ensureSystemConnection() orelse return .unknown;

        var sid_buf: [64]u8 = undefined;
        const sid = self.currentSessionId(&sid_buf) orelse {
            std.log.info("could not resolve session id; skipping polkit agent probe", .{});
            return .unknown;
        };

        const subject = buildUnixSessionSubject(sid) orelse return .unknown;

        const params = glib.Variant.new(
            "(@(sa{sv})ss)",
            subject,
            "en_US.UTF-8",
            PROBE_PATH.ptr,
        );

        var err: ?*glib.Error = null;
        const result = conn.callSync(
            POLKIT_NAME,
            POLKIT_AUTH_PATH,
            POLKIT_AUTH_IFACE,
            "RegisterAuthenticationAgent",
            params,
            null,
            .{},
            -1,
            null,
            &err,
        );

        if (err) |e| {
            defer glib.Error.free(e);
            const msg: []const u8 = if (e.f_message) |m| std.mem.span(m) else "";
            if (std.mem.indexOf(u8, msg, "already exists") != null) return .present;
            std.log.debug("polkit agent probe inconclusive: {s}", .{msg});
            return .unknown;
        }

        if (result) |r| r.unref();
        self.unregisterProbeAgent(sid);
        return .absent;
    }

    fn unregisterProbeAgent(self: *DBus, sid: []const u8) void {
        const conn = self.ensureSystemConnection() orelse return;
        const subject = buildUnixSessionSubject(sid) orelse return;
        const params = glib.Variant.new("(@(sa{sv})s)", subject, PROBE_PATH.ptr);
        var err: ?*glib.Error = null;
        const r = conn.callSync(
            POLKIT_NAME,
            POLKIT_AUTH_PATH,
            POLKIT_AUTH_IFACE,
            "UnregisterAuthenticationAgent",
            params,
            null,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("UnregisterAuthenticationAgent probe failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
        }
        if (r) |res| res.unref();
    }

    fn buildUnixSessionSubject(sid: []const u8) ?*glib.Variant {
        const vt = glib.VariantType.new("a{sv}");
        defer vt.free();

        const builder = glib.VariantBuilder.new(vt);
        builder.add("{sv}", "session-id", glib.Variant.new("s", sid.ptr));
        const dict = builder.end();
        _ = &builder;

        return glib.Variant.new("(s@a{sv})", "unix-session", dict);
    }

    fn currentSessionId(self: *DBus, buf: []u8) ?[]const u8 {
        if (std.c.getenv("XDG_SESSION_ID")) |env_ptr| {
            const env = std.mem.span(env_ptr);
            if (env.len > 0 and env.len < buf.len) {
                @memcpy(buf[0..env.len], env);
                buf[env.len] = 0;
                return buf[0..env.len :0];
            }
        }
        return self.sessionIdFromLogind(buf);
    }

    fn sessionIdFromLogind(self: *DBus, buf: []u8) ?[]const u8 {
        const conn = self.ensureSystemConnection() orelse return null;
        const pid: u32 = @intCast(std.os.linux.getpid());

        const params = glib.Variant.new("(u)", pid);
        const reply_type = glib.VariantType.new("(o)");
        defer reply_type.free();
        var err: ?*glib.Error = null;
        const result = conn.callSync(
            LOGIND_NAME,
            LOGIND_PATH,
            LOGIND_MANAGER_IFACE,
            "GetSessionByPID",
            params,
            reply_type,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            std.log.info("logind GetSessionByPID failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return null;
        }
        const res = result orelse return null;
        defer res.unref();

        const path_v = res.getChildValue(0);
        defer path_v.unref();

        var len: usize = 0;
        const path_c = path_v.getString(&len);
        const session_path = path_c[0..len];

        return self.sessionIdProperty(session_path, buf);
    }

    fn sessionIdProperty(self: *DBus, session_path: []const u8, buf: []u8) ?[]const u8 {
        const conn = self.ensureSystemConnection() orelse return null;

        var path_buf: [256]u8 = undefined;
        if (session_path.len >= path_buf.len) return null;
        @memcpy(path_buf[0..session_path.len], session_path);
        path_buf[session_path.len] = 0;
        const path_z = path_buf[0..session_path.len :0];

        const params = glib.Variant.new(
            "(ss)",
            "org.freedesktop.login1.Session",
            "Id",
        );
        const reply_type = glib.VariantType.new("(v)");
        defer reply_type.free();
        var err: ?*glib.Error = null;
        const result = conn.callSync(
            LOGIND_NAME,
            path_z,
            "org.freedesktop.DBus.Properties",
            "Get",
            params,
            reply_type,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("logind Session.Id get failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return null;
        }
        const res = result orelse return null;
        defer res.unref();

        const variant = res.getChildValue(0);
        defer variant.unref();
        const inner = variant.getVariant();
        defer inner.unref();

        var len: usize = 0;
        const id_c = inner.getString(&len);
        if (len == 0 or len >= buf.len) return null;
        @memcpy(buf[0..len], id_c[0..len]);
        buf[len] = 0;
        return buf[0..len :0];
    }
};
