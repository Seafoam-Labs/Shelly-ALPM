using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakInstallFromBundleFile : Command<FlatpakBundleInstallSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakBundleInstallSettings settings)
    {
        AnsiConsole.MarkupLine("[yellow]Installing flatpak bundle...[/]");
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (sender, args) =>
        {
            AnsiConsole.MarkupLine($"[yellow]{args.Message.EscapeMarkup()}[/]");
        };
        manager.InstallAppFromBundle(settings.BundlePath, settings.SystemWide);
        return 0;
    }
}