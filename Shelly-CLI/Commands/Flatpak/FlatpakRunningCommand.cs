using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakRunningCommand : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeRunning();
        }

        AnsiConsole.MarkupLine("[yellow]Currently running flatpack instances on machine...[/]");
        var result = new FlatpakManager().GetRunningInstances();

        if (result.Count > 0)
        {
            var table = new Table();
            table.AddColumn("Id");
            table.AddColumn("Pid");

            foreach (var pkg in result.OrderBy(pkg => pkg.Pid))
            {
                table.AddRow(
                    pkg.AppId,
                    pkg.Pid.ToString()
                );
            }

            AnsiConsole.Write(table);
            return 0;
        }

        AnsiConsole.MarkupLine("[green]No instances running[/]");
        return 0;
    }

    private static int HandleUiModeRunning()
    {
        var result = new FlatpakManager().GetRunningInstances();
        UiFrames.Frame(result.OrderBy(pkg => pkg.Pid).ToList());
        UiFrames.Info($"Running instances: {result.Count}");
        return 0;
    }
}
