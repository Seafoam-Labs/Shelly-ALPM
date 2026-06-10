using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakInstallFromRefFile : Command<FlatpakRemoteRefFileInstallSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakRemoteRefFileInstallSettings settings)
    {
        AnsiConsole.MarkupLine("[yellow]Installing flatpak app...[/]");
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (sender, args) => { AnsiConsole.MarkupLine($"[yellow]{args.Message.EscapeMarkup()}[/]"); };
        manager.InstallAppFromRef(settings.RefFilePath, settings.SystemWide);
        return 0;
    }
}
