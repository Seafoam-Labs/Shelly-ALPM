const std = @import("std");
const diagnostics = @import("diagnostics");
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
            std.log.warn("Could not connect to the selected D-Bus session. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
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
            std.log.warn("Could not send the tray settings signal over D-Bus. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
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
            std.log.info("Could not check whether the authorization service is running. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
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
            std.log.info("Could not identify the login session; the authorization-agent check was skipped.", .{});
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
            std.log.warn("Could not unregister the temporary authorization-agent probe. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
            glib.Error.free(e);
        }
        if (r) |res| res.unref();
    }

    fn buildUnixSessionSubject(sid: []const u8) ?*glib.Variant {
        const vt = glib.VariantType.new("a{sv}");
        defer vt.free();

        const builder = glib.VariantBuilder.new(vt);
        defer builder.unref();
        builder.add("{sv}", "session-id", glib.Variant.new("s", sid.ptr));
        const dict = builder.end();

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
            std.log.info("Could not identify the login session through logind. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
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
            std.log.warn("Could not identify the login session through logind. {0f}", .{diagnostics.safe(e.f_message orelse "unknown")});
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

    // -----------------------------------------------------------------------
    // logind power actions (firmware reboot/shutdown prompts)
    // -----------------------------------------------------------------------

    /// `Manager.CanReboot()`/`CanPowerOff()` result. `.unknown` means the probe
    /// itself failed (older systemd, no logind): fall back to showing the prompt
    /// and let polkit decide.
    pub const PowerCapability = enum {
        yes,
        challenge,
        no,
        na,
        unknown,

        pub fn fromString(value: []const u8) PowerCapability {
            if (std.mem.eql(u8, value, "yes")) return .yes;
            if (std.mem.eql(u8, value, "challenge")) return .challenge;
            if (std.mem.eql(u8, value, "no")) return .no;
            if (std.mem.eql(u8, value, "na")) return .na;
            return .unknown;
        }

        /// `no`/`na` (container, no logind) disable the action button; a failed
        /// probe keeps it enabled so the user still gets the consent prompt.
        pub fn buttonEnabled(self: PowerCapability) bool {
            return switch (self) {
                .yes, .challenge, .unknown => true,
                .no, .na => false,
            };
        }
    };

    pub const PowerOutcome = enum { success, cancelled, failed };

    pub fn canReboot(self: *DBus) PowerCapability {
        return self.powerCapability("CanReboot");
    }

    pub fn canPowerOff(self: *DBus) PowerCapability {
        return self.powerCapability("CanPowerOff");
    }

    fn powerCapability(self: *DBus, method: [:0]const u8) PowerCapability {
        const conn = self.ensureSystemConnection() orelse return .unknown;
        const reply_type = glib.VariantType.new("(s)");
        defer reply_type.free();
        var err: ?*glib.Error = null;
        const result = conn.callSync(LOGIND_NAME, LOGIND_PATH, LOGIND_MANAGER_IFACE, method, null, reply_type, .{}, 5_000, null, &err);
        if (err) |e| {
            std.log.info("Could not probe logind {0s}. {1f}", .{ method, diagnostics.safe(e.f_message orelse "unknown") });
            glib.Error.free(e);
            return .unknown;
        }
        const res = result orelse return .unknown;
        defer res.unref();
        const child = res.getChildValue(0);
        defer child.unref();
        var len: usize = 0;
        const value = child.getString(&len)[0..len];
        return PowerCapability.fromString(value);
    }

    /// `Manager.Reboot(b interactive)`. Never call without a prior now/later
    /// consent dialog: with `allow_active=yes` polkit does not prompt, so the
    /// dialog is the only gate. Runs on a worker thread (polkit may block).
    pub fn reboot(self: *DBus, interactive: bool) PowerOutcome {
        return self.powerAction("Reboot", interactive);
    }

    pub fn powerOff(self: *DBus, interactive: bool) PowerOutcome {
        return self.powerAction("PowerOff", interactive);
    }

    fn powerAction(self: *DBus, method: [:0]const u8, interactive: bool) PowerOutcome {
        const conn = self.ensureSystemConnection() orelse return .failed;
        const params = glib.Variant.new("(b)", @as(c_int, @intFromBool(interactive)));
        const reply_type = glib.VariantType.new("()");
        defer reply_type.free();
        var err: ?*glib.Error = null;
        // No timeout: an interactive polkit challenge waits for the user.
        const result = conn.callSync(LOGIND_NAME, LOGIND_PATH, LOGIND_MANAGER_IFACE, method, params, reply_type, .{}, -1, null, &err);
        if (err) |e| {
            const outcome = classifyPowerGError(e);
            std.log.info("logind {0s} did not complete ({1s}). {2f}", .{ method, @tagName(outcome), diagnostics.safe(e.f_message orelse "unknown") });
            glib.Error.free(e);
            return outcome;
        }
        if (result) |r| r.unref();
        return .success;
    }
};

/// Polkit cancel surfaces as AccessDenied: systemd treats
/// `org.freedesktop.PolicyKit1.Error.Cancelled` as a denial (-EACCES), which
/// sd-bus maps to `org.freedesktop.DBus.Error.AccessDenied`. Auth denials and
/// cancels both get the friendly "cancelled" note, never an error dialog.
pub fn classifyPowerError(name: []const u8, message: []const u8) DBus.PowerOutcome {
    if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.AccessDenied") or
        std.mem.endsWith(u8, name, ".NotPrivileged") or
        std.mem.indexOf(u8, name, "Cancelled") != null)
    {
        return .cancelled;
    }
    var lower_buf: [256]u8 = undefined;
    const n = @min(message.len, lower_buf.len);
    const lower = std.ascii.lowerString(&lower_buf, message[0..n]);
    if (std.mem.indexOf(u8, lower, "cancel") != null or
        std.mem.indexOf(u8, lower, "dismiss") != null or
        std.mem.indexOf(u8, lower, "denied") != null or
        std.mem.indexOf(u8, lower, "not authorized") != null)
    {
        return .cancelled;
    }
    return .failed;
}

fn classifyPowerGError(err: *const glib.Error) DBus.PowerOutcome {
    var name: []const u8 = "";
    var name_buf: [128]u8 = undefined;
    if (gio.DBusError.getRemoteError(err)) |name_z| {
        const span = std.mem.span(name_z);
        const n = @min(span.len, name_buf.len);
        @memcpy(name_buf[0..n], span[0..n]);
        name = name_buf[0..n];
        glib.free(@ptrCast(name_z));
    }
    const message = if (err.f_message) |m| std.mem.span(m) else "";
    return classifyPowerError(name, message);
}

const testing = std.testing;

test "power capability parsing and button gating" {
    const C = DBus.PowerCapability;
    try testing.expectEqual(C.yes, C.fromString("yes"));
    try testing.expectEqual(C.challenge, C.fromString("challenge"));
    try testing.expectEqual(C.no, C.fromString("no"));
    try testing.expectEqual(C.na, C.fromString("na"));
    try testing.expectEqual(C.unknown, C.fromString("bogus"));
    try testing.expectEqual(C.unknown, C.fromString(""));

    try testing.expect(C.yes.buttonEnabled());
    try testing.expect(C.challenge.buttonEnabled());
    // Probe failure falls back to showing the prompt.
    try testing.expect(C.unknown.buttonEnabled());
    try testing.expect(!C.no.buttonEnabled());
    try testing.expect(!C.na.buttonEnabled());
}

test "power error classification maps auth cancel and denial to cancelled" {
    const O = DBus.PowerOutcome;
    try testing.expectEqual(O.cancelled, classifyPowerError("org.freedesktop.DBus.Error.AccessDenied", "Access denied"));
    try testing.expectEqual(O.cancelled, classifyPowerError("org.freedesktop.login1.NotPrivileged", ""));
    try testing.expectEqual(O.cancelled, classifyPowerError("org.freedesktop.PolicyKit1.Error.Cancelled", ""));
    try testing.expectEqual(O.cancelled, classifyPowerError("", "Authentication dialog dismissed"));
    try testing.expectEqual(O.cancelled, classifyPowerError("", "The user cancelled the request"));
    try testing.expectEqual(O.cancelled, classifyPowerError("", "Not authorized"));
    try testing.expectEqual(O.failed, classifyPowerError("org.freedesktop.DBus.Error.Failed", "Operation failed"));
    try testing.expectEqual(O.failed, classifyPowerError("", ""));
    try testing.expectEqual(O.failed, classifyPowerError("org.freedesktop.DBus.Error.NoReply", "Message recipient disconnected"));
}

test "power GError classification reads the remote error name" {
    const denied = gio.DBusError.newForDbusError("org.freedesktop.DBus.Error.AccessDenied", "Access denied");
    defer glib.Error.free(denied);
    try testing.expectEqual(DBus.PowerOutcome.cancelled, classifyPowerGError(denied));

    const failed = gio.DBusError.newForDbusError("org.freedesktop.DBus.Error.Failed", "Something broke");
    defer glib.Error.free(failed);
    try testing.expectEqual(DBus.PowerOutcome.failed, classifyPowerGError(failed));
}
