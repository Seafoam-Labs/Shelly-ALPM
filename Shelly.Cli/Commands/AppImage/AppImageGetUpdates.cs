using System.CommandLine;
using Microsoft.VisualBasic;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageGetUpdates : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list-updates", "Find Updates for an AppImage");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageGetUpdates();
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

        var result = await GetAppImageUpdates();
        foreach (var update in result)
        {
            console.WriteLine(AnsiUtilities.Colorize($"{update.Name} {update.Version} is available",
                ConsoleColor.Green));
        }

        if (result.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No updates available", ConsoleColor.Yellow));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        JsonPackFrame.WriteToStdout(await GetAppImageUpdates());
    }

    private static async Task<List<AppImageUpdateDto>> GetAppImageUpdates()
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);
        return await manager.CheckForAppImageUpdates();
    }
}