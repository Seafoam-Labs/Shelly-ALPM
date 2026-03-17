using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakRemoveCommand : Command<FlatpakPackageSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeRemove(settings);
        }

        var manager = new FlatpakManager();
        var result = manager.UninstallApp(settings.Packages, settings.RemoveUnused);

        AnsiConsole.MarkupLine("[yellow]" + result.EscapeMarkup() + "[/]");
        return 0;
    }

    private static int HandleUiModeRemove(FlatpakPackageSettings settings)
    {
        var manager = new FlatpakManager();
        var result = manager.UninstallApp(settings.Packages, settings.RemoveUnused);

        Console.Error.WriteLine(result);
        return 0;
    }
}
