using System.ComponentModel;
using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakUpgrade : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        AnsiConsole.MarkupLine("[yellow]Updating all user flatpak apps...[/]");
        var userResult = FlatpakManager.UpdateAllUserFlatpak();
        AnsiConsole.MarkupLine("[yellow]" + userResult.EscapeMarkup() + "[/]");

        AnsiConsole.MarkupLine("[yellow]Updating all system flatpak apps...[/]");
        var systemResult = FlatpakManager.UpdateAllSystemFlatpak();
        AnsiConsole.MarkupLine("[yellow]" + systemResult.EscapeMarkup() + "[/]");

        return 0;
    }
}