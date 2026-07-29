using GLib;

public class ShellyConfig {
    public bool tray_enabled = true;
    public int tray_check_interval_hours = 72;
    public bool use_weekly_schedule = false;
    public int[]   scheduled_days = {};
    public int scheduled_hour = -1;
    public int scheduled_minute = 0;
    public bool use_symbolic_tray = true;
    public string? tray_icon_path = null;
    public string? tray_updates_icon_path = null;
}

public class ConfigReader : Object {

    private ShellyConfig? _cached = null;

    private string config_path () {
        return Path.build_filename (
                                    Environment.get_user_config_dir (), "shelly", "settings.json"
        );
    }

    public ShellyConfig load () {
        if (_cached != null)return _cached;

        var path = config_path ();
        if (!FileUtils.test (path, FileTest.EXISTS)) {
            stdout.printf ("[shelly-config] %s not found — using defaults\n", path);
            return _cached = new ShellyConfig ();
        }

        try {
            string raw;
            FileUtils.get_contents (path, out raw);

            var parser = new Json.Parser ();
            parser.load_from_data (raw);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                printerr ("[shelly-notifications] Unexpected JSON — using defaults\n");
                return _cached = new ShellyConfig ();
            }

            var obj = root.get_object ();
            var cfg = new ShellyConfig ();

            if (obj.has_member ("TrayEnabled"))
                cfg.tray_enabled = obj.get_boolean_member ("TrayEnabled");
            if (obj.has_member ("TrayCheckIntervalHours"))
                cfg.tray_check_interval_hours = (int) obj.get_int_member ("TrayCheckIntervalHours");
            if (obj.has_member ("UseWeeklySchedule"))
                cfg.use_weekly_schedule = obj.get_boolean_member ("UseWeeklySchedule");

            if (obj.has_member ("DaysOfWeek")) {
                int[] days = {};
                obj.get_array_member ("DaysOfWeek").foreach_element ((_, __, node) => {
                    if (node.get_node_type () != Json.NodeType.VALUE)return;
                    if (node.get_value_type () == typeof (string)) {
                        int d = day_name_to_int (node.get_string ());
                        if (d >= 0)days += d;
                    } else {
                        days += (int) node.get_int ();
                    }
                });
                cfg.scheduled_days = days;
            }
            if (obj.has_member ("Time")
                && obj.get_member ("Time").get_node_type () != Json.NodeType.NULL) {
                var parts = obj.get_string_member ("Time").split (":");
                if (parts.length >= 2) {
                    cfg.scheduled_hour = int.parse (parts[0]);
                    cfg.scheduled_minute = int.parse (parts[1]);
                }
            }

            if (obj.has_member ("UseSymbolicTray"))
                cfg.use_symbolic_tray = obj.get_boolean_member ("UseSymbolicTray");
            if (obj.has_member ("TrayIconPath")
                && obj.get_member ("TrayIconPath").get_node_type () != Json.NodeType.NULL)
                cfg.tray_icon_path = obj.get_string_member ("TrayIconPath");
            if (obj.has_member ("TrayUpdatesIconPath")
                && obj.get_member ("TrayUpdatesIconPath").get_node_type () != Json.NodeType.NULL)
                cfg.tray_updates_icon_path = obj.get_string_member ("TrayUpdatesIconPath");

            stdout.printf ("[shelly-config] Loaded from %s\n", path);
            return _cached = cfg;
        } catch (Error e) {
            printerr ("[shelly-notifications] Load error: %s — using defaults\n", e.message);
            return _cached = new ShellyConfig ();
        }
    }

    public void refresh () {
        _cached = null;
        stdout.printf ("[shelly-config] Cache cleared\n");
    }

    private static int day_name_to_int (string name) {
        switch (name.down ()) {
        case "sunday" : return 0;
        case "monday":    return 1;
        case "tuesday":   return 2;
        case "wednesday": return 3;
        case "thursday":  return 4;
        case "friday":    return 5;
        case "saturday":  return 6;
        default:          return -1;
        }
    }
}
