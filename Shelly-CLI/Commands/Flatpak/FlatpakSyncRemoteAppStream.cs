using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakSyncRemoteAppStream : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        (var result, var stringResult) = new FlatpakManager().UpdateAppstream();

        if (result)
        {
            AnsiConsole.MarkupLine($"[green]{stringResult}[/]");
            return 0;
        }

        AnsiConsole.MarkupLine($"[red]{stringResult}[/]");
        return 1;
    }
}