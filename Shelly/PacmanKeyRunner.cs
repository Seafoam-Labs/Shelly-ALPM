using System.Diagnostics;

namespace Shelly;

internal static class PacmanKeyRunner
{
    internal static int Run(string args, bool uiMode = false)
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

        if (uiMode)
        {
            process.OutputDataReceived += (_, e) =>
            {
                if (e.Data != null) Console.WriteLine(e.Data);
            };
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data != null) Console.Error.WriteLine(e.Data);
            };
        }
        else
        {
            process.OutputDataReceived += (_, e) =>
            {
                if (e.Data != null) Console.WriteLine(e.Data);
            };
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data != null) Console.Error.WriteLine(e.Data);
            };
        }

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.WaitForExit();

        return process.ExitCode;
    }
}
