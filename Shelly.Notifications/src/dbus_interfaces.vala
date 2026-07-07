[DBus (name = "org.kde.StatusNotifierWatcher")]
public interface KdeStatusNotifierWatcher : Object {
    public abstract void register_status_notifier_item (string service) throws DBusError, IOError;

    [DBus (name = "IsStatusNotifierHostRegistered")]
    public abstract bool is_status_notifier_host_registered { owned get; }

}

[DBus (name = "org.freedesktop.StatusNotifierWatcher")]
public interface FreedesktopStatusNotifierWatcher : Object {
    public abstract void register_status_notifier_item (string service) throws DBusError, IOError;

    [DBus (name = "IsStatusNotifierHostRegistered")]
    public abstract bool is_status_notifier_host_registered { owned get; }
}

[DBus (name = "org.freedesktop.Application")]
public interface FreedesktopApplication : Object {
    public abstract async void activate (GLib.HashTable<string, GLib.Variant> platform_data) throws DBusError, IOError;
}

[DBus (name = "org.freedesktop.Notifications")]
public interface FreedesktopNotifications : Object {
    public abstract async uint notify (string app_name,
        uint replaces_id,
        string app_icon,
        string summary,
        string body,
        string[]                             actions,
        GLib.HashTable<string, GLib.Variant> hints,
        int expire_timeout) throws DBusError, IOError;

    public signal void action_invoked (uint32 id, string action_key);
    public signal void notification_closed (uint32 id, uint32 reason);
    public signal void activation_token (uint32 id, string activation_token);
}
