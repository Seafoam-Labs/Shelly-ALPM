using GLib;

public class AppRunner {

    private const string[] APP_PATHS = {
        "/usr/bin/shelly-ui",
        "/opt/shelly/Shelly-UI"
    };

    public static void launch_app_if_not_running () {
        if (is_process_running ("shelly-ui")) {
            stdout.printf ("[shelly-runner] shelly-ui is already running\n");
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

            Pid child_pid;
            Process.spawn_async (
                null,
                argv,
                null,
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

    private static bool is_process_running (string name) {
        try {
            int exit_status;
            GLib.Process.spawn_sync (
                                     null, { "pgrep", "-x", name }, null,
                                     SpawnFlags.SEARCH_PATH
                                     | SpawnFlags.STDOUT_TO_DEV_NULL
                                     | SpawnFlags.STDERR_TO_DEV_NULL,
                                     null, null, null, out exit_status
            );
            return exit_status == 0;
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
