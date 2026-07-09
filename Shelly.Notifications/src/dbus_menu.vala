public delegate void MenuActionHandler (int item_id);

[DBus (name = "com.canonical.dbusmenu")]
public class DBusMenuHandler : Object {

    public uint version         { get { return 3; } }
    public string text_direction  { owned get { return "ltr"; } }
    public string status          { owned get { return "normal"; } }
    public string[] icon_theme_path { owned get { return {}; } }

    public signal void items_properties_updated ([DBus (signature = "a(ia{sv})")] GLib.Variant updated_props,
        [DBus (signature = "a(ias)")]    GLib.Variant removed_props);
    public signal void layout_updated (uint revision, int parent);

    private uint _revision = 1;
    private MenuActionHandler? _on_action;
    private string _last_check_label = "Last check: Never";
    private SyncModel? _updates = null;

    private const int ID_ROOT = 0;
    private const int ID_OPEN = 1;
    private const int ID_UPD_PKGS = 2;
    private const int ID_CHECK = 3;
    private const int ID_LASTCHECK = 4;
    private const int ID_SEP = 5;
    private const int ID_SUB_STD = 101;
    private const int ID_SUB_AUR = 102;
    private const int ID_SUB_FLAT = 103;
    private const int ID_SEP2 = 98;
    private const int ID_EXIT = 99;

    private const int BASE_PKG = 200;

    public DBusMenuHandler (owned MenuActionHandler? on_action = null) {
        _on_action = (owned) on_action;
    }

    public void get_layout (int parent_id, int recursion_depth,
                            string[] property_names,
                            out uint revision,
                            [DBus (signature = "(ia{sv}av)")] out GLib.Variant layout)
    throws DBusError, IOError {
        revision = _revision;
        layout = build_item (parent_id, recursion_depth);
    }

    [DBus (signature = "a(ia{sv})")]
    public GLib.Variant get_group_properties (int[] ids, string[] property_names)
    throws DBusError, IOError {
        var b = new GLib.VariantBuilder (new GLib.VariantType ("a(ia{sv})"));
        foreach (var id in ids) {
            b.add ("(i@a{sv})", id, build_props (id, property_names));
        }
        return b.end ();
    }

    public new GLib.Variant get_property (int id, string name) throws DBusError, IOError {
        switch (name) {
        case "type" :
            bool is_sep = (id == ID_SEP || id == ID_SEP2);
            return new GLib.Variant.string (is_sep ? "separator" : "standard");
        case "label" :
            var dl = dynamic_label (id);
            return new GLib.Variant.string (dl ?? label_for (id));
        case "enabled" :
            return new GLib.Variant.boolean (is_enabled (id));
        case "visible":
            return new GLib.Variant.boolean (true);
        case "children-display":
            bool is_sub = (id == ID_SUB_STD || id == ID_SUB_AUR || id == ID_SUB_FLAT);
            return new GLib.Variant.string (is_sub ? "submenu" : "");
        default:
            return new GLib.Variant.string ("");
        }
    }

    public void event (int id, string event_id, GLib.Variant data, uint timestamp)
    throws DBusError, IOError {
        if (event_id == "clicked")dispatch (id);
    }

    public bool about_to_show (int id) throws DBusError, IOError {
        return false;
    }

    internal void notify_updates (SyncModel model) {
        _updates = model;
        _revision++;
        layout_updated (_revision, ID_ROOT);
    }

    internal void set_last_check_label (string label) {
        _last_check_label = label;
        _revision++;
        layout_updated (_revision, ID_ROOT);
    }

    internal void force_redraw () {
        _revision++;
        layout_updated (_revision, ID_ROOT);
    }

    private void dispatch (int id) {
        stdout.printf ("[menu] clicked id=%d (%s)\n", id, label_for (id));
        if (is_dynamic_info (id))return;
        if (_on_action != null)_on_action (id);
    }

    private int[] get_root_children () {
        int[] r = {};
        r += ID_OPEN;
        if (_updates != null && _updates.total () > 0)r += ID_UPD_PKGS;
        r += ID_CHECK;
        r += ID_LASTCHECK;
        r += ID_SEP;
        if (_updates != null) {
            if (_updates.packages.length > 0)r += ID_SUB_STD;
            if (_updates.aur.length > 0)r += ID_SUB_AUR;
            if (_updates.flatpaks.length > 0)r += ID_SUB_FLAT;
            if (_updates.total () > 0)r += ID_SEP2;
        }
        r += ID_EXIT;
        return r;
    }

    private GLib.Variant build_item (int id, int depth) {
        var children = new GLib.VariantBuilder (new GLib.VariantType ("av"));

        if (depth != 0) {
            var next = depth < 0 ? -1 : depth - 1;

            if (id == ID_ROOT) {
                foreach (var cid in get_root_children ())
                    children.add ("v", build_item (cid, next));
            } else if (id == ID_SUB_STD && _updates != null) {
                for (int i = 0; i < (int) _updates.packages.length; i++)
                    children.add ("v", build_item (BASE_PKG + i, next));
            } else if (id == ID_SUB_AUR && _updates != null) {
                int offset = (int) _updates.packages.length;
                for (int i = 0; i < (int) _updates.aur.length; i++)
                    children.add ("v", build_item (BASE_PKG + offset + i, next));
            } else if (id == ID_SUB_FLAT && _updates != null) {
                int offset = (int) _updates.packages.length + (int) _updates.aur.length;
                for (int i = 0; i < (int) _updates.flatpaks.length; i++)
                    children.add ("v", build_item (BASE_PKG + offset + i, next));
            }
        }


        return new GLib.Variant.tuple ({
            new GLib.Variant.int32 (id),
            build_props (id, {}),
            children.end ()
        });
    }

    private GLib.Variant build_props (int id, string[] wanted) {
        bool all = wanted.length == 0;
        var b = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));

        if (id == ID_ROOT)return b.end ();

        bool is_sep = (id == ID_SEP || id == ID_SEP2);
        if (is_sep) {
            if (want (all, wanted, "type"))
                b.add ("{sv}", "type", new GLib.Variant.string ("separator"));
            return b.end ();
        }

        bool is_sub = (id == ID_SUB_STD || id == ID_SUB_AUR || id == ID_SUB_FLAT);

        if (want (all, wanted, "type"))
            b.add ("{sv}", "type", new GLib.Variant.string ("standard"));

        if (want (all, wanted, "label")) {
            var dl = dynamic_label (id);
            b.add ("{sv}", "label", new GLib.Variant.string (dl ?? label_for (id)));
        }

        if (want (all, wanted, "enabled"))
            b.add ("{sv}", "enabled", new GLib.Variant.boolean (is_enabled (id)));

        if (want (all, wanted, "visible"))
            b.add ("{sv}", "visible", new GLib.Variant.boolean (true));

        if (is_sub && want (all, wanted, "children-display"))
            b.add ("{sv}", "children-display", new GLib.Variant.string ("submenu"));

        return b.end ();
    }

    private string label_for (int id) {
        switch (id) {
        case ID_OPEN:      return "Open Shelly";
        case ID_UPD_PKGS:  return "Update Packages";
        case ID_CHECK:     return "Check for Updates";
        case ID_LASTCHECK: return _last_check_label;
        case ID_EXIT:      return "Exit";
        case ID_SUB_STD:
            return _updates != null
                    ? "Standard (%d)".printf ((int) _updates.packages.length) : "Standard";
        case ID_SUB_AUR:
            return _updates != null
                    ? "AUR (%d)".printf ((int) _updates.aur.length) : "AUR";
        case ID_SUB_FLAT:
            return _updates != null
                    ? "Flatpak (%d)".printf ((int) _updates.flatpaks.length) : "Flatpak";
        default: return "";
        }
    }

    private string ? dynamic_label (int id) {
        if (_updates == null || id < BASE_PKG)return null;

        int idx = id - BASE_PKG;
        int std_count = (int) _updates.packages.length;
        int aur_count = (int) _updates.aur.length;
        int flat_count = (int) _updates.flatpaks.length;

        if (idx < std_count)
            return _updates.packages[idx].display_label ();
        idx -= std_count;

        if (idx < aur_count)
            return _updates.aur[idx].display_label ();
        idx -= aur_count;

        if (idx < flat_count)
            return _updates.flatpaks[idx].display_label ();

        return null;
    }

    private bool is_dynamic_info (int id) {
        return id >= BASE_PKG;
    }

    private bool is_enabled (int id) {
        if (id == ID_ROOT || id == ID_SEP || id == ID_SEP2)return false;
        if (id == ID_LASTCHECK)return false;
        if (is_dynamic_info (id))return false;
        return true;
    }

    private bool want (bool all, string[] names, string name) {
        if (all)return true;
        foreach (var n in names)if (n == name)return true;
        return false;
    }
}
