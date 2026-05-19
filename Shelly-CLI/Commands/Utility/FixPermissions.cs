using System.Diagnostics;
using PackageManager.Utilities;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Utility;

public class FixPermissions : Command<FixPermissionsSettings>
{
    public override int Execute(CommandContext context, FixPermissionsSettings settings)
    {
        RootElevator.EnsureRootExectuion();

        var user = Environment.GetEnvironmentVariable("SUDO_USER");
        if (string.IsNullOrEmpty(user) || user == "root")
        {
            AnsiConsole.MarkupLine("[red] Could not determine invoking user (SUDO_USER not set). [/]");
            return 1;
        }
        
        var paths = new[]
        {
            XdgPaths.ShellyConfig(),
            XdgPaths.ShellyCache(),
            XdgPaths.ShellyData()
        };

        var existing = paths.Where(Directory.Exists).ToList();
        if (existing.Count == 0)
        {
            if (!Program.IsUiMode)
            {
                AnsiConsole.MarkupLine("[yellow] No Shelly XDG directories present to fix. [/]");
            }
            return 0;
        }

        var failed = false;
        foreach (var path in existing)
        {
            var args = new List<string> { "-R", $"{user}:{user}", path };
            var psi = new ProcessStartInfo
            {
                FileName = "chown",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            foreach (var a in args) psi.ArgumentList.Add(a);

            try
            {
                using var proc = Process.Start(psi);
                if (proc == null)
                {
                    failed = true;
                    AnsiConsole.MarkupLine($"[red] Failed to start chown for {Markup.Escape(path)} [/]");
                    continue;
                }
                proc.WaitForExit();
                if (proc.ExitCode != 0)
                {
                    failed = true;
                    var err = proc.StandardError.ReadToEnd().Trim();
                    AnsiConsole.MarkupLine(
                        $"[red] chown failed for {Markup.Escape(path)} (exit {proc.ExitCode}): {Markup.Escape(err)} [/]");
                }
                else if (!Program.IsUiMode)
                {
                    AnsiConsole.MarkupLine($"[green] Fixed ownership: {Markup.Escape(path)} [/]");
                }
            }
            catch (Exception ex)
            {
                failed = true;
                AnsiConsole.MarkupLine(
                    $"[red] Error running chown for {Markup.Escape(path)}: {Markup.Escape(ex.Message)} [/]");
            }
        }

        return failed ? 1 : 0;
    }
}
