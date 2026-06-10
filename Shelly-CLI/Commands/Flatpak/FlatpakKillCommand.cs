using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakKillCommand : Command<FlatpakPackageSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeKill(settings);
        }

        AnsiConsole.MarkupLine("[yellow]Killing selected flatpak app...[/]");
        var flatpakManager = new FlatpakManager();
        flatpakManager.FlatpakEvent += (sender, args) =>
        {
            AnsiConsole.MarkupLine($"[yellow]{args.Message.EscapeMarkup()}[/]");
        };
        flatpakManager.KillApp(settings.Packages);

        return 0;
    }

    private static int HandleUiModeKill(FlatpakPackageSettings settings)
    {
        UiFrames.Info("Killing selected flatpak app...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (sender, args) => UiFrames.Info(args.Message);
        manager.KillApp(settings.Packages);
        UiFrames.TxFinish(true, "Flatpak app killed.", "Failed to kill flatpak app.");
        return 0;
    }
}