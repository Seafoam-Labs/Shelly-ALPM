const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const gobject = bindings.gobject;
const glib = bindings.glib;

const TrayService: [:0]const u8 = "org.shelly.Notifications";
const TrayPath: [:0]const u8 = "/org/shelly/Notifications";
const TrayInterface: [:0]const u8 = "org.shelly.Notifications";

pub const TrayDBus = struct {
    connection: ?*gio.DBusConnection = null,

    pub fn deinit(self: *TrayDBus) void {
        if (self.connection) |conn| {
            conn.as(gobject.Object).unref();
            self.connection = null;
        }
    }

    pub fn updatesMadeInUi(self: *TrayDBus) void {
        self.callTray("UpdatesMadeInUi");
    }

    fn ensureConnection(self: *TrayDBus) ?*gio.DBusConnection {
        if (self.connection) |conn| return conn;
        var err: ?*glib.Error = null;
        const conn = gio.busGetSync(.session, null, &err);
        if (err) |e| {
            std.log.warn("tray bus_get_sync failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return null;
        }
        self.connection = conn;
        return conn;
    }

    fn callTray(self: *TrayDBus, method: [:0]const u8) void {
        const conn = self.ensureConnection() orelse return;
        gio.DBusConnection.call(
            conn,
            TrayService,
            TrayPath,
            TrayInterface,
            method,
            null, // parameters
            null, // reply_type
            .{}, // flags (G_DBUS_CALL_FLAGS_NONE)
            -1, // timeout (default)
            null, // cancellable
            null, // callback (null = ignore result)
            null, // user_data
        );
    }
};
