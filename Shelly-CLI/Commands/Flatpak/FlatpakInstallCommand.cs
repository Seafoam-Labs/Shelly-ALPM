using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakInstallCommand : Command<FlatpakPackageSettings>
{
    public override int Execute(CommandContext context, FlatpakPackageSettings settings)
    {
        if (Program.IsUiMode) return HandleUiModeInstall(settings);

        AnsiConsole.MarkupLine("[yellow]Installing flatpak app...[/]");
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => { AnsiConsole.MarkupLine($"[yellow]{args.Message.EscapeMarkup()}[/]"); };
        manager.InstallApp(settings.Packages, settings.Remote, settings.IsUser, settings.Branch ?? "stable",
            settings.IsRuntime);
        return 0;
    }

    private static int HandleUiModeInstall(FlatpakPackageSettings settings)
    {
        UiFrames.TxStart("Installing flatpak app...");
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => UiFrames.Info(args.Message);
        manager.InstallApp(settings.Packages, settings.Remote, settings.IsUser, settings.Branch ?? "stable",
            settings.IsRuntime);
        UiFrames.TxDone("Flatpak install complete.");
        return 0;
    }
}