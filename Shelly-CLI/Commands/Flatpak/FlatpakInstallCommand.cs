using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakInstallCommand : Command<FlatpakPackageSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeInstall(settings);
        }

        AnsiConsole.MarkupLine("[yellow]Installing flatpak app...[/]");
        var manager = new FlatpakManager();
        var result = manager.InstallApp(settings.Packages, settings.Remote, settings.IsUser, settings.Branch ?? "stable");

        AnsiConsole.MarkupLine("[yellow]Installed: " + result.EscapeMarkup() + "[/]");

        return 0;
    }

    private static int HandleUiModeInstall(FlatpakPackageSettings settings)
    {
        Console.Error.WriteLine("Installing flatpak app...");
        var manager = new FlatpakManager();
        var result = manager.InstallApp(settings.Packages, settings.Remote, settings.IsUser);

        Console.Error.WriteLine("Installed: " + result);

        return 0;
    }
}
