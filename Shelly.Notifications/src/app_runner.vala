using GLib;

public class AppRunner {

    private const string[] APP_PATHS = {
        "/usr/bin/shelly-ui",
        "/opt/shelly/Shelly-UI"
    };

    private const string SHELLY_UI_SERVICE = "com.shellyorg.shelly";
    private const string SHELLY_UI_PATH = "/com/shellyorg/shelly";

    private static string? _activation_token = null;

    /*
     * Stores the single-use XDG activation token that the tray host
     * (e.g. plasmashell, gnome-shell's appindicator
     * extension, etc.) hands us via ProvideXdgActivationToken right
     * before it delivers an Activate/menu-click event. Without it,
     * Wayland compositors refuse to shift focus (focus-stealing
     * prevention) and only mark the window as demanding attention.
     */
    public static void set_activation_token (string token) {
        _activation_token = token;
    }

    private static string ? take_activation_token () {
        var token = _activation_token;
        _activation_token = null;
        return token;
    }

    public static async void launch_app_if_not_running () {
        var token = take_activation_token ();

        if (yield try_activate_running_instance (token)) {
            stdout.printf ("[shelly-runner] shelly-ui already running — activated existing window\n");
            return;
        }

        string? app_path = null;
        foreach (var p in APP_PATHS) {
            if (FileUtils.test (p, FileTest.IS_EXECUTABLE)) {
                app_path = p;
                break;
            }
        }
        if (app_path == null) {
            printerr ("[shelly-notifications] shelly-ui not found at known paths\n");
            return;
        }

        try {
            string[] argv = { "setsid", app_path };

            var envp = Environ.get ();
            if (token != null)
                envp = Environ.set_variable (envp, "XDG_ACTIVATION_TOKEN", token, true);

            Pid child_pid;
            Process.spawn_async (
                null,
                argv,
                envp,
                SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
                null,
                out child_pid
            );

            stdout.printf ("[app] Launched %s (detached, pid %d)\n", app_path, (int) child_pid);
        } catch (Error e) {
            printerr ("[shelly-notifications] Could not launch shelly-ui: %s\n", e.message);
        }
    }

    public static async void spawn_terminal_with_command (string command) throws Error {
        var terminal = find_terminal ();
        if (terminal == null) {
            printerr ("[shelly-notifications] No terminal emulator found\n");
            return;
        }

        var bash_cmd = "%s; echo; read -rp 'Press Enter to close...'".printf (command);

        string[] argv;
        if (terminal == "gnome-terminal" || terminal == "kgx") {
            argv = { terminal, "--", "bash", "-c", bash_cmd };
        } else {
            argv = { terminal, "-e", "bash", "-c", bash_cmd };
        }

        var proc = new Subprocess.newv (argv, SubprocessFlags.NONE);
        yield proc.wait_async (null);
    }

    /*
     * Asks a running shelly-ui instance to raise and focus its window via the
     * org.freedesktop.Application interface that GtkApplication exports on the
     * session bus. Returns false if no instance owns the name (i.e. not running).
     *
     * The token travels as "activation-token" in platform_data; GTK reads it in
     * gtk_application_impl_wayland_before_emit() and uses it for xdg-activation
     * when the app calls gtk_window_present().
     */
    private static async bool try_activate_running_instance (string? token) {
        try {
            var app = yield Bus.get_proxy<FreedesktopApplication> (BusType.SESSION,
                SHELLY_UI_SERVICE,
                SHELLY_UI_PATH,
                DBusProxyFlags.DO_NOT_AUTO_START, null);

            var platform_data = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
            if (token != null) {
                platform_data["activation-token"] = new GLib.Variant.string (token);
                platform_data["desktop-startup-id"] = new GLib.Variant.string (token);
            }

            yield app.activate (platform_data);
            return true;
        } catch (Error e) {
            return false;
        }
    }

    private static string ? find_terminal () {
        var from_env = Environment.get_variable ("TERMINAL");
        if (from_env != null && is_command_available (from_env))return from_env;

        string[] candidates = {
            "alacritty", "rio", "ghostty", "kitty",
            "konsole", "kgx", "gnome-terminal",
            "xfce4-terminal", "lxterminal", "xterm",
            "st", "foot", "terminator"
        };

        foreach (var t in candidates) {
            if (is_command_available (t))return t;
        }

        return null;
    }

    private static bool is_command_available (string cmd) {
        var path_env = Environment.get_variable ("PATH") ?? "/usr/bin:/bin";
        foreach (var dir in path_env.split (":")) {
            if (FileUtils.test (Path.build_filename (dir, cmd), FileTest.IS_EXECUTABLE))
                return true;
        }
        return false;
    }
}
