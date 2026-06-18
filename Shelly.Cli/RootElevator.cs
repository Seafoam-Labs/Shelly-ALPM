using System.Diagnostics;

namespace Shelly.Cli;

public static class RootElevator
{
    public static void EnsureRootExectuion()
    {
        if (Environment.UserName.Equals("root", StringComparison.OrdinalIgnoreCase)) return;

        var args = Environment.GetCommandLineArgs();
        var exe = Environment.ProcessPath ?? args[0];

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = "sudo",
            ArgumentList = { exe },
            UseShellExecute = false
        };
        foreach (var arg in args.Skip(1)) process.StartInfo.ArgumentList.Add(arg);

        process.Start();
        process.WaitForExit();
        Environment.Exit(process.ExitCode);
    }
}