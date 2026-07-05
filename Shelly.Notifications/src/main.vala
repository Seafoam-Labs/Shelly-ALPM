using GLib;

public class ShellyApp : Object {

    private const string SERVICE_NAME = "org.shelly.Notifications";
    private const string SHELLY_UI_SERVICE = "com.shellyorg.shelly";
    private const string SHELLY_UI_PATH = "/com/shellyorg/shelly";

    private MainLoop loop;
    private StatusNotifierItem tray_item;
    private DBusMenuHandler menu_handler;
    private ConfigReader config_reader;
    private UpdateService update_service;
    private NotificationHandler notification_handler;
    private ShellyUiReceiver ui_receiver;
    private Cancellable _sleep_cancel = new Cancellable ();

    public ShellyApp (MainLoop loop) {
        this.loop = loop;
        this.config_reader = new ConfigReader ();
        this.update_service = new UpdateService ();
        this.notification_handler = new NotificationHandler ();
        this.tray_item = new StatusNotifierItem ();

        this.ui_receiver = new ShellyUiReceiver (
                                                 () => {
            config_reader.refresh ();
            tray_item.apply_config (config_reader.load ());
            _sleep_cancel.cancel ();
        },
                                                 () => {
            _sleep_cancel.cancel ();
        });

        this.menu_handler = new DBusMenuHandler ((id) => {
            switch (id) {
                case 1:
                    AppRunner.launch_app_if_not_running ();
                    break;
                case 2:
                    do_update_packages.begin ((obj, res) => {
                    try { do_update_packages.end (res); } catch (Error e) { printerr ("[shelly-notifications] %s\n", e.message); }
                });
                    break;
                case 3:
                    run_update_check.begin (true, (obj, res) => {
                    try { run_update_check.end (res); } catch (Error e) { printerr ("[shelly-notifications] %s\n", e.message); }
                });
                    break;
                case 99:
                    stdout.printf ("[shelly] Exiting...\n");
                    quit_shelly_ui ();
                    loop.quit ();
                    break;
            }
        });
    }

    public void start () {
        Bus.own_name (
                      BusType.SESSION,
                      SERVICE_NAME,
                      BusNameOwnerFlags.NONE,
                      (conn, name) => {},
                      on_name_acquired,
                      on_name_lost
        );
    }

    private void on_name_acquired (DBusConnection conn, string name) {
        stdout.printf ("[shelly] Service name acquired: %s\n", name);

        try { conn.register_object<StatusNotifierItem> ("/StatusNotifierItem", tray_item); } catch (IOError e) { printerr ("[shelly-notifications] %s\n", e.message); loop.quit (); return; }

        try { conn.register_object<DBusMenuHandler> ("/MenuBar", menu_handler); } catch (IOError e) { printerr ("[shelly-notifications] %s\n", e.message); loop.quit (); return; }

        try { conn.register_object<ShellyUiReceiver> ("/org/shelly/Notifications", ui_receiver); } catch (IOError e) { printerr ("[shelly-notifications] %s\n", e.message); loop.quit (); return; }

        var sni_name = "org.freedesktop.StatusNotifierItem-%d-1"
             .printf ((int) Posix.getpid ());
        Bus.own_name_on_connection (
                                    conn, sni_name, BusNameOwnerFlags.NONE,
                                    (c, n) => on_sni_name_acquired (n),
                                    (c, n) => printerr ("[shelly-notifications] Lost SNI bus name: %s\n", n)
        );

        tray_item.apply_config (config_reader.load ());

        run_update_check.begin (true, (obj, res) => {
            try { run_update_check.end (res); } catch (Error e) { printerr ("[shelly-notifications] Initial check error: %s\n", e.message); }
        });

        start_background_loop.begin ((obj, res) => {
            start_background_loop.end (res);
        });
    }

    private async void start_background_loop () {
        while (true) {
            var config = config_reader.load ();
            var delay_secs = NextNotification.get_next_seconds (config);

            stdout.printf ("[loop] Next automatic check in %.1f h\n", delay_secs / 3600.0);

            _sleep_cancel = new Cancellable ();
            yield sleep_cancellable (delay_secs, _sleep_cancel);

            try { yield run_update_check (); } catch (Error e) { printerr ("[shelly-notifications] Check error: %s\n", e.message); }
        }
    }

    private async void sleep_cancellable (uint seconds, Cancellable cancel) {
        SourceFunc resume = sleep_cancellable.callback;
        uint source_id = 0;
        ulong cancel_id = 0;

        source_id = Timeout.add_seconds (seconds, () => {
            resume ();
            return Source.REMOVE;
        });

        cancel_id = cancel.connect (() => {
            Source.remove (source_id);
            Idle.add (resume);
        });

        yield;

        cancel.disconnect (cancel_id);
    }

    private async void do_update_packages () throws Error {
        yield AppRunner.spawn_terminal_with_command ("shelly");
        yield run_update_check (false);
    }

    private async void run_update_check (bool notify = true) throws Error {
        var model = yield update_service.check_for_updates ();

        tray_item.set_updates_pending (model.total () > 0);
        menu_handler.notify_updates (model);
        menu_handler.set_last_check_label (
            new DateTime.now_local ().format ("Last check: %H:%M %m/%d")
        );

        if (notify) {
            if (model.total () > 0) {
                yield notification_handler.send ("%d package update%s available".printf (
                    model.total (), model.total () == 1 ? "" : "s"
                ));
            } else {
                yield notification_handler.send ("No updates available");
            }
        }

        stdout.printf ("[shelly-notifications] Check complete — %d update(s)\n", model.total ());
    }


    private void quit_shelly_ui () {
        try {
            var sui = Bus.get_proxy_sync<GtkActions> (BusType.SESSION,
                SHELLY_UI_SERVICE, SHELLY_UI_PATH, DBusProxyFlags.NONE, null);

            GLib.Variant[] no_params = {};
            var platform_data = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
            sui.activate ("quit", no_params, platform_data);
        } catch (Error e) {
            stdout.printf ("[shelly-notifications] shelly-ui not reachable for quit: %s\n", e.message);
        }
    }

    private void on_sni_name_acquired (string sni_name) {
        register_with_watcher.begin (sni_name, (obj, res) => {
            try { register_with_watcher.end (res); } catch (Error e) { printerr ("[shelly-notifications] Watcher error: %s\n", e.message); }
        });
    }

    private async void register_with_watcher (string sni_name) throws Error {
        try {
            var w = yield Bus.get_proxy<KdeStatusNotifierWatcher> (BusType.SESSION,
                "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                DBusProxyFlags.NONE, null);

            w.register_status_notifier_item (sni_name);
            return;
        } catch (Error e) {
            stdout.printf ("[shelly-notif] org.kde.StatusNotifierWatcher unavailable: %s\n", e.message);
        }
        try {
            var w = yield Bus.get_proxy<FreedesktopStatusNotifierWatcher> (BusType.SESSION,
                "org.freedesktop.StatusNotifierWatcher", "/StatusNotifierWatcher",
                DBusProxyFlags.NONE, null);

            w.register_status_notifier_item (sni_name);
            return;
        } catch (Error e) {
            stdout.printf ("[shelly-notif] org.freedesktop.StatusNotifierWatcher unavailable: %s\n", e.message);
        }
        printerr ("[shelly-notifications] WARNING: No StatusNotifierWatcher found.\n");
    }

    private void on_name_lost (DBusConnection? conn, string name) {
        if (conn == null)
            printerr ("[shelly-notifications] Could not connect to the session bus.\n");
        else
            printerr ("[shelly-notifications] Could not acquire '%s' — another instance may be running.\n", name);
        loop.quit ();
    }
}

void main (string[] args) {
    var loop = new MainLoop ();
    var shelly = new ShellyApp (loop);
    shelly.start ();
    loop.run ();
}
