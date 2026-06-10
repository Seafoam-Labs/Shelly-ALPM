using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakRemoveCommand : Command<FlatpakRemoveSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakRemoveSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeRemove(settings);
        }

        var manager = new FlatpakManager();
        manager.FlatpakEvent += (sender, args) =>
        {
            AnsiConsole.MarkupLine($"[yellow]{args.Message.EscapeMarkup()}[/]");
        };
        var dto = manager.FindAppByNameOrId(settings.Packages);
        manager.UninstallApp(settings.Packages, settings.RemoveUnused);

        if (settings.RemoveConfig)
        {
            AnsiConsole.MarkupLine(RemoveConfig(dto.Id) == 0
                ? "[Green]Local flatpak config removed[/]"
                : "[yellow]Failed to remove local flatpak config[/]");
        }

        return 0;
    }

    private static int HandleUiModeRemove(FlatpakRemoveSettings settings)
    {
        UiFrames.Info("Removing flatpak app...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (sender, args) => UiFrames.Info(args.Message);
        manager.UninstallApp(settings.Packages, settings.RemoveUnused);
        UiFrames.TxFinish(true, "Flatpak removal complete.", "Flatpak removal failed.");
        return 0;
    }

    private static int RemoveConfig(string appId)
    {
        //lets not delete the .var folder like i did :(
        if (string.IsNullOrWhiteSpace(appId))
        {
            return 1;
        }

        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".var", "app", appId
        );

        if (Directory.Exists(path))
            Directory.Delete(path, recursive: true);

        return 0;
    }
}