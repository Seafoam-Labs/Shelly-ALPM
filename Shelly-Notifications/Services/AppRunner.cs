using System.Diagnostics;

namespace Shelly_Notifications.Services;

public static class AppRunner
{
    public static void LaunchAppIfNotRunning(string args)
    {
        const string appName = "shelly-ui";
        const string optPath = "/opt/shelly/Shelly-UI";
        const string appPath = "/usr/bin/shelly-ui";

        string targetPath;
        if (File.Exists(appPath))
        {
            targetPath = appPath;
        }
        else if (File.Exists(optPath))
        {
            targetPath = optPath;
        }
        else
        {
            Console.WriteLine($"[Shell-Notifications][AppRunner] {appName} not found in {optPath} or {appPath}");
            return;
        }

        var existing = Process.GetProcessesByName(appName);
        if (existing.Length > 0)
        {
            Console.WriteLine($"[Shell-Notifications][AppRunner] {appName} already running");
            return;
        }

        Console.WriteLine($"[Shell-Notifications][AppRunner] Launching {targetPath}");
        Process.Start(new ProcessStartInfo
        {
            FileName = targetPath,
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true,
        });
    }

    public static async Task SpawnTerminalWithCommandAsync(string command)
    {
        var terminal = Environment.GetEnvironmentVariable("TERMINAL") ?? "alacritty";

        var process = Process.Start(new ProcessStartInfo
        {
            FileName = terminal,
            Arguments = $"-e bash -c \"{command}\"",
            UseShellExecute = false,
        });
        
        //auuuugh default to alacritty could spawn shelly maybe once we have a better home page that update 
        //all or maybe we can just give notification 
        await process!.WaitForExitAsync();
    }
}