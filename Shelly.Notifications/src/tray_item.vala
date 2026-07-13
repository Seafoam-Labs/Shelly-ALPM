[DBus (name = "org.kde.StatusNotifierItem")]
public class StatusNotifierItem : Object {

    private string _idle_icon = "system-software-update-symbolic";
    private string _updates_icon = "software-update-available-symbolic";
    private string _icon_name = "system-software-update-symbolic";
    private bool _updates_pending = false;

    public string category        { owned get { return "ApplicationStatus"; } }
    public string id              { owned get { return "Shelly"; } }
    public string title           { owned get { return _("Shelly Notifications"); } }
    public string status          { owned get { return "Active"; } }
    public string icon_name       { owned get { return _icon_name; } }
    public string icon_theme_path { owned get { return ""; } }
    public bool item_is_menu    { get { return false; } }
    public ObjectPath menu           { owned get { return new ObjectPath ("/MenuBar"); } }

    public signal void new_icon ();
    public signal void new_status (string status);
    public signal void new_tool_tip ();

    public void context_menu (int x, int y) throws DBusError, IOError {}

    public void activate (int x, int y) throws DBusError, IOError {
        AppRunner.launch_app_if_not_running ();
    }

    internal void apply_config (ShellyConfig config) {
        bool has_custom = (config.tray_icon_path ?? "").length > 0
            && (config.tray_updates_icon_path ?? "").length > 0;

        if (has_custom) {
            _idle_icon = config.tray_icon_path;
            _updates_icon = config.tray_updates_icon_path;
        } else {
            string pref_idle = config.use_symbolic_tray ? "shelly-shell-symbolic" : "shelly-tray";
            string pref_updates = config.use_symbolic_tray ? "shelly-updates-symbolic" : "shelly-update";

            _idle_icon = icon_exists (pref_idle) ? pref_idle : "system-software-update-symbolic";
            _updates_icon = icon_exists (pref_updates) ? pref_updates : "software-update-available-symbolic";
        }

        stdout.printf ("[shelly-tray] Icons: idle=%s  updates=%s\n", _idle_icon, _updates_icon);

        var next = _updates_pending ? _updates_icon : _idle_icon;
        if (next != _icon_name) {
            _icon_name = next;
            emit_icon_changed ();
        }
    }

    internal void set_updates_pending (bool pending) {
        _updates_pending = pending;
        var next = pending ? _updates_icon : _idle_icon;
        if (next == _icon_name)return;
        _icon_name = next;
        emit_icon_changed ();
    }

    private void emit_icon_changed () {
        stdout.printf ("[shelly-tray] Icon → %s\n", _icon_name);
        new_icon ();
        new_status ("Active");
    }

    private static bool icon_exists (string name) {
        string[] dirs = {
            "/usr/share/icons/hicolor",
            "/usr/local/share/icons/hicolor",
            Path.build_filename (Environment.get_home_dir (), ".local", "share", "icons", "hicolor")
        };
        string[] subdirs = { "symbolic/apps", "scalable/apps", "48x48/apps", "128x128/apps" };
        string[] exts = { ".svg", ".png" };

        foreach (var d in dirs) {
            foreach (var sub in subdirs) {
                foreach (var ext in exts) {
                    if (FileUtils.test (Path.build_filename (d, sub, name + ext), FileTest.EXISTS))
                        return true;
                }
            }
        }
        return false;
    }
}
