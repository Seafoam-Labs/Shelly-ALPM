public class NotificationHandler : Object {

    private const string DEFAULT_ACTION_KEY = "default";
    private const uint RECENTLY_CLOSED_WINDOW_SECONDS = 10;

    private FreedesktopNotifications proxy;
    private uint _last_id = 0;
    private GLib.HashTable<uint, uint8> notification_ids = new GLib.HashTable<uint, uint8> (GLib.direct_hash, GLib.direct_equal);
    private GLib.HashTable<uint, int64?> recently_closed_notification_ids = new GLib.HashTable<uint, int64?> (GLib.direct_hash, GLib.direct_equal);
    private bool _watchers_registered = false;

    public async void send (string body) {
        try {
            prune_recently_closed_notifications ();
            if (proxy == null) {
                proxy = yield Bus.get_proxy<FreedesktopNotifications> (BusType.SESSION,
                    "org.freedesktop.Notifications",
                    "/org/freedesktop/Notifications",
                    DBusProxyFlags.NONE, null);
            }

            register_watchers ();

            var hints = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);

            _last_id = yield proxy.notify ("Shelly",
                _last_id,
                "shelly",
                "Shelly Notifications",
                body,
                { DEFAULT_ACTION_KEY, "Open Shelly" },
                hints,
                5000);

            notification_ids[_last_id] = 0;
        } catch (Error e) {
            printerr ("[shelly-notifications] Could not send notification: %s\n", e.message);
        }
    }

    private void register_watchers () {
        if (_watchers_registered) {
            return;
        }

        _watchers_registered = true;

        proxy.action_invoked.connect (handle_action_invoked);
        proxy.notification_closed.connect (handle_notification_closed);
    }

    private void handle_action_invoked (uint32 id, string action_key) {
        if (action_key != DEFAULT_ACTION_KEY) {
            return;
        }

        bool was_active = notification_ids.remove (id);
        bool was_recently_closed = recently_closed_notification_ids.remove (id);

        if (!was_active && !was_recently_closed) {
            return;
        }

        AppRunner.launch_app_if_not_running ();
    }

    private void handle_notification_closed (uint32 id, uint32 reason) {
        if (notification_ids.remove (id)) {
            int64 now = GLib.get_real_time () / 1000000;
            recently_closed_notification_ids[(uint) id] = now;
        }
    }

    private void prune_recently_closed_notifications () {
        int64 now = GLib.get_real_time () / 1000000;

        recently_closed_notification_ids.foreach_remove ((id, closed_at) => {
            if (closed_at == null) {
                return true;
            }

            return (now - closed_at) > RECENTLY_CLOSED_WINDOW_SECONDS;
        });
    }
}
