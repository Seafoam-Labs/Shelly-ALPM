using System.Diagnostics;
using Shelly.Cli.Commands;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli;

public static class PacmanKeyRunner
{
    public static int Run(IShellyConsole console, string args)
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "pacman-key",
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            }
        };

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data != null) console.WriteLine(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data != null) console.WriteLine(Colorize(e.Data, ConsoleColor.Red));
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.WaitForExit();

        return process.ExitCode;
    }
}
