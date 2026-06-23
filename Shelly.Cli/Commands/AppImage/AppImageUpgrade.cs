using System.CommandLine;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageUpgrade : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("upgrade", "Upgrades all AppImages");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageUpgrade();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);

        var updates = await manager.CheckForAppImageUpdates();

        if (updates.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No updates available for any AppImage.", ConsoleColor.Yellow));
            return;
        }

        foreach (var update in updates)
        {
            console.WriteLine(AnsiUtilities.Colorize($"Updating {update.Name} to {update.Version}",
                ConsoleColor.Green));
            await AppImageSinglePaneOutput.Output(console, manager, x => x.RunUpdate(update), NoConfirm);
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);
        var updates = await manager.CheckForAppImageUpdates();
        foreach (var update in updates)
        {
            await UiModeOutput.Run(manager, x => x.RunUpdate(update));
        }
    }
}