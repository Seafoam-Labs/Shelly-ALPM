using System.Diagnostics;

namespace Shelly.Cli;

public static class RootElevator
{
    public static void EnsureRootExectuion(params string[] extraArgs)
    {
        if (Environment.UserName.Equals("root", StringComparison.OrdinalIgnoreCase)) return;

        var args = Environment.GetCommandLineArgs();
        var exe = Environment.ProcessPath ?? args[0];

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = ResolveElevator(),
            ArgumentList = { exe },
            UseShellExecute = false
        };
        foreach (var arg in args.Skip(1)) process.StartInfo.ArgumentList.Add(arg);
        foreach (var extra in extraArgs) process.StartInfo.ArgumentList.Add(extra);

        process.Start();
        process.WaitForExit();
        Environment.Exit(process.ExitCode);
    }
    

    public static bool TryGetCallingUser(out string user, out string home)
    {
        user = Environment.GetEnvironmentVariable("SUDO_USER")
            ?? Environment.GetEnvironmentVariable("DOAS_USER")
            ?? "";
        home = "";

        if (string.IsNullOrEmpty(user) || user.Equals("root", StringComparison.OrdinalIgnoreCase))
            return false;

        home = ResolveHome(user);
        return !string.IsNullOrEmpty(home);
    }


    public static int RunFlatpakAsUser(string user, string home, IEnumerable<string> flatpakArgs)
    {
        var exe = Environment.ProcessPath ?? Environment.GetCommandLineArgs()[0];
        var elevator = ResolveElevator();

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = elevator,
            UseShellExecute = false
        };

        var xdgDataHome = Path.Combine(home, ".local", "share");

        // doas -u <user> / sudo -u <user>
        process.StartInfo.ArgumentList.Add("-u");
        process.StartInfo.ArgumentList.Add(user);

        // Use env to set HOME/XDG_DATA_HOME for the child so Flatpak finds the user installation.
        process.StartInfo.ArgumentList.Add("env");
        process.StartInfo.ArgumentList.Add($"HOME={home}");
        process.StartInfo.ArgumentList.Add($"XDG_DATA_HOME={xdgDataHome}");

        process.StartInfo.ArgumentList.Add(exe);
        foreach (var arg in flatpakArgs)
            process.StartInfo.ArgumentList.Add(arg);

        process.Start();
        process.WaitForExit();
        return process.ExitCode;
    }

    private static string ResolveHome(string user)
    {
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = "getent",
                ArgumentList = { "passwd", user },
                UseShellExecute = false,
                RedirectStandardOutput = true
            };

            process.Start();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();

            if (process.ExitCode != 0 || string.IsNullOrWhiteSpace(output))
                return "";

            // passwd format: name:passwd:uid:gid:gecos:home:shell
            var fields = output.Trim().Split(':');
            return fields.Length >= 6 ? fields[5] : "";
        }
        catch
        {
            return "";
        }
    }

    private static string ResolveElevator()
    {
        var configured = Environment.GetEnvironmentVariable("SHELLY_ELEVATOR");
        if (!string.IsNullOrWhiteSpace(configured))
            return configured;

        
        foreach (var tool in new[] { "doas", "sudo" })
        {
            if (IsOnPath(tool))
                return tool;
        }

        return "sudo";
    }
    
    private static bool IsOnPath(string tool)
    {
        var pathVar = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathVar))
            return false;

        foreach (var dir in pathVar.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir))
                continue;

            var candidate = Path.Combine(dir, tool);
            if (File.Exists(candidate))
                return true;
        }

        return false;
    }
}